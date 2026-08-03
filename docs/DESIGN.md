# aperture — high-level design

Status: **draft for discussion**. No code exists yet. Everything below is a proposal;
sections marked **SPIKE** are unresolved and must be validated before committing to the
surrounding design.

## 1. Thesis

`marginalia` annotates each candidate with **one line**, because the completion API it
implements (`annotation-function` / `affixation-function`) returns a string appended to the
candidate. That ceiling is structural, not a configuration choice.

`aperture` adds a second surface: a **pane** that renders arbitrary, multi-line, fontified
context for the currently selected candidate, dispatched on the candidate's *completion
category*, and working for **any** `completing-read` — not just commands that were written
with preview in mind.

The relationship in one line:

> marginalia is to a marginal note as aperture is to a full commentary.

## 2. Scope

**In scope**
- A per-session detail pane driven by selection changes in the minibuffer.
- A previewer registry keyed on completion category, extensible by third parties.
- A set of built-in previewers for the categories that ship with Emacs and consult.
- Coexistence with `vertico`, `vertico-buffer-mode`, `marginalia`, `orderless`, `embark`.

**Explicitly out of scope**
- Candidate collection, filtering, sorting, or matching. That is vertico/consult/orderless.
- Replacing or wrapping consult's sources.
- Actions on candidates. That is embark.
- Child frames / posframe. Deferred; the display mechanism is pluggable so this can be
  added later without touching the core.
- Multi-frame sessions.

Rationale: the previous attempt in this space (`pawanspace/emacs-telescope`) reimplemented
filtering, sources, and actions from scratch and did all three worse than the existing
ecosystem, while never building the thing that was actually missing. aperture builds only
the missing piece.

## 3. Layers

```
┌─ aperture-consult.el ──┐  ┌─ aperture-vertico.el ─┐   soft deps, optional
│  consult :state bridge │  │  frontend adapter     │
└───────────┬────────────┘  └───────────┬───────────┘
            │                           │
┌───────────▼───────────────────────────▼───────────┐
│ aperture.el (core, no hard deps beyond Emacs)     │
│  · session lifecycle    · previewer registry      │
│  · selection driver     · dispatch + normalization│
│  · debounce/cancel      · pane display + restore  │
└───────────────────────┬───────────────────────────┘
                        │
        ┌───────────────▼────────────────┐
        │ aperture-previewers.el         │
        │  file · buffer · symbol ·      │
        │  location · package · kill-ring│
        └────────────────────────────────┘
```

### 3.1 Selection driver

Needs two signals: *a completion session started/ended*, and *the selected candidate
changed*.

- Session end: `minibuffer-exit-hook`, at depth 90 so vertico-buffer restores its own
  state before we undo ours.
- Session start: **not `minibuffer-setup-hook` at any depth.** The constraint is
  two-sided and that hook cannot satisfy it:
  - We must run *after* `minibuffer-completion-table` is set, or the category is nil and
    nothing activates. `completing-read-default` sets that table from inside its own
    `minibuffer-with-setup-hook` lambda, so any negative-depth hook runs too early.
  - We must run *before* vertico-buffer picks a window, or there is no list window to
    point it at.

  `vertico--setup` sits exactly between the two — it runs after the table is set, and its
  own `:after` method is what calls `vertico-buffer--setup`. Session start is therefore
  `:before` advice on `vertico--setup`, installed by the frontend (the core does not know
  this timing exists). Found the hard way: with a `-90` hook the package silently never
  activated, and what looked like a layout bug was stock vertico-buffer behaviour with
  aperture entirely absent.
- Selection change: **vertico exposes no hook for this.** Two options:
  - (a) a buffer-local `post-command-hook` in the minibuffer that compares a cached
    `vertico--index` and input string, then reads `(vertico--candidate)`;
  - (b) `:after` advice on `vertico--exhibit`.

  **Proposed: (a).** It is buffer-local (dies with the minibuffer, no global state), it
  cannot break other packages, and it depends on only two vertico symbols rather than on
  the shape of a function body. Both are internals either way — this is the one
  unavoidable coupling, and it should be isolated in `aperture-vertico.el`.

The core does not know about vertico. It defines a small frontend protocol —
`active-p`, `current-candidate`, `candidate-index`, `install-hook`, `remove-hook` — and
`aperture-vertico.el` supplies an implementation. A future icomplete/mct/default-UI
frontend plugs in the same way.

### 3.2 Previewer registry and dispatch

Deliberately mirrors `marginalia-annotator-registry` so it's familiar:

```elisp
(defcustom aperture-previewer-registry
  '((file        . aperture-preview-file)
    (buffer      . aperture-preview-buffer)
    (symbol      . aperture-preview-symbol)
    (function    . aperture-preview-symbol)
    (variable    . aperture-preview-symbol)
    (command     . aperture-preview-symbol)
    (package     . aperture-preview-package)
    (bookmark    . aperture-preview-bookmark)
    (kill-ring   . aperture-preview-kill-ring))
  ...)
```

Category comes from `completion-metadata-get` on the active completion table. Because the
category is often coarser than the command (`consult-ripgrep` and `consult-line` share
`consult-location`), there is also `aperture-command-previewers`, an alist keyed on the
command that opened the minibuffer.

**Resolution order:** command override → consult `:state` bridge (§3.5) → category
previewer → nothing (pane stays closed).

### 3.3 The previewer contract

A previewer is a function of one argument, the candidate string. It returns one of:

| Return value | Meaning |
|---|---|
| `nil` | nothing to show; pane is cleared |
| a string | sugar for `(:content STR)` |
| a plist | the general form (below) |
| a function | **async**: called with a callback that receives any of the above |

Plist keys:

- `:content` — string to insert into the pane buffer.
- `:buffer` — an existing buffer to display instead. aperture displays it as-is and
  **never kills a buffer it did not create**.
- `:mode` — major mode to apply to `:content`, or `:file PATH` to let `set-auto-mode`
  decide. Fontification is the core's job, not the previewer's.
- `:goto` — position or line number to center on.
- `:highlight` — list of `(BEG . END)` regions, or a function run in the pane buffer.
- `:title` — header-line string.
- `:cancel` — thunk to abort in-flight work (kill the process, drop the request) when the
  selection moves away. Required for anything that shells out.
- `:cache-key` — optional; if unchanged, the core skips re-rendering.
- `:cost` — `free` | `cheap` (default) | `expensive`. See below.

Sync previewers stay trivial to write; only the ones that need async pay for it.

**`:cost` exists for the fast path, not the slow one.** Debouncing and the guards below
already handle expensive previewers; `:cost` earns its place at the other end. `symbol`,
`buffer`, and `kill-ring` previewers are pure in-memory lookups, and for those the debounce
is pure lag with no benefit. `:cost free` bypasses the debounce entirely and renders
synchronously on the same command, which is the difference between `M-x` feeling instant
and merely feeling fast. `expensive` gets a longer debounce and is the first thing a
conservative `aperture-key` setting downgrades to on-demand.

**Rendering rules owned by the core, not previewers:**
- Debounce on an idle timer (`aperture-delay`, default 0.15s), except for `:cost free`.
- Generation counter — a callback whose generation is stale is discarded, so fast cursor
  movement can never render the wrong candidate.
- Keep the previous content visible until the replacement is ready (no flicker, no
  "Loading…" strobe).
- Errors in a previewer are caught, logged to a session log buffer, and shown as a short
  message in the pane — never a stack trace into the user's session, and never silently
  swallowed into a misleading "no preview available".

**Guards (§3.3a), owned by the core.** These are what make a live-by-default pane safe;
see §3.6. Modelled directly on consult's, which have held up under `consult-preview-key`
defaulting to `any` for years:

- **Partial preview, not skipping.** Files over `aperture-partial-size` (1MB) are read as a
  bounded head chunk (`aperture-partial-chunk`, 10KB) rather than refused. A 5MB log file
  is a perfectly good preview if you read the first 10KB.
- **Exclusions.** `aperture-excluded-files` skips remote (TRAMP) and gpg paths by default;
  `aperture-excluded-buffers` likewise. This is the single most important guard for a live
  default — a synchronous remote read is the one failure mode debouncing cannot rescue.
- **Buffer cap.** `aperture-max-count` bounds how many preview buffers stay live.
- **Environment.** Previewers run with `non-essential` bound to `t`, file-local and
  dir-local variables disabled, and messages inhibited, so previewing never prompts, never
  triggers auth, and never runs project code.
- When a guard suppresses a preview, the pane **says so and names the variable**. Silence
  here is how users conclude the package is broken.

### 3.4 Layout

**Exactly one supported layout: candidate list and preview pane side by side, both in
windows.**

The variant where the list stays in the minibuffer and the pane opens to the right is
explicitly **not supported**. It is neither telescope nor stock vertico, and shipping it
would mean defending a layout nobody actually wants. Narrowing here is what makes the
product legible.

**Consequence, stated plainly because it reverses an earlier decision.** §9 previously
recorded "vertico-buffer is not required," resolved on the strength of M0 running fine
without it. That resolution was correct only under the wider scope. Side-by-side means the
candidate list must live in a window, so **getting the list into a window is a hard
prerequisite**, and vertico-buffer (or an equivalent) is a dependency rather than an
enhancement.

```
+---------------------------------------+
|  original buffer — stays visible      |
+-------------------+-------------------+
|  candidate list   |  preview pane     |  <- aperture-height
+-------------------+-------------------+
|  minibuffer (prompt)                  |
+---------------------------------------+
```

**The aperture area is height-capped; the original buffer stays visible above it.**
`aperture-height` accepts lines or a frame fraction. Below a minimum usable height the top
split is skipped rather than producing an unusable sliver — degrade, don't fight the frame.

**Split ordering is load-bearing, not cosmetic.** consult previews into
`(minibuffer-selected-window)` (§3.5), which is the *original* window object. So every
split must leave that object where we want the pane: bottom-right.

1. `(split-window orig aperture-height 'above)` — the new window goes *above* showing the
   same buffer, and `orig` remains as the bottom strip. Verified: for `SIDE = 'above`, a
   positive SIZE sets the height of the window being split, so this reads as "give the
   aperture area N lines." (Negative SIZE sizes the new window instead; the general
   `split-window` docstring is easy to misread here, so prefer an explicit `window-resize`
   over relying on sign convention.)
2. `(split-window orig nil 'left)` — the list window goes left, `orig` remains bottom-right.

Both steps verified to keep `orig` live and correctly positioned; step 2 is the exact
operation M0 confirmed preserves `minibuffer-selected-window`. Splitting in the other
order, or with the other SIDE, hands the pane role to a window consult will never preview
into — a silent failure that looks like "preview goes to the wrong place."

- **The pane** is placed by direct window manipulation — `split-window` plus
  `set-window-buffer` on a window reference we hold — never by asking `display-buffer`
  (§3.5b). Geometry is `aperture-height`, `aperture-side` and `aperture-width`, applied by
  us.
- **Not a child frame.** posframe was considered and rejected: no TTY support, focus and
  redisplay bugs, multi-monitor problems, and `vertico-posframe` is among the suspects for
  the display interference in §3.5b. Ordinary windows stay inspectable with the same tools
  as everything else in Emacs.
- **The list window** is vertico-buffer's job, but its *placement* is ours. vertico-buffer
  picks a window by calling `display-buffer` on a throwaway buffer, then does
  `set-window-buffer win (current-buffer)` — the minibuffer buffer itself — and layers
  presentation on top (vertico-buffer.el:139-142). aperture makes that placement
  deterministic by binding `display-buffer-overriding-action` around vertico-buffer's
  setup, which sits at the top of `display-buffer`'s precedence chain and therefore wins
  over whatever a given config is doing. M0 proved a plain action is not enough.
- Rationale for borrowing rather than reimplementing: doing it ourselves means owning
  cursor-in-non-selected-windows, face remapping, mode-line, `vertico-count` sizing,
  prompt hiding, resize on `pre-redisplay-functions`, and restore — roughly 150 fiddly
  lines carrying years of accumulated bug fixes (there is a `gh:minad/vertico#496`
  workaround in the restore path alone). None of that is what makes aperture interesting.
  We keep ownership where it matters — the pane and the geometry — and borrow the solved
  part.
- Save `current-window-configuration` at session start; restore unconditionally on exit,
  including on `C-g` and on error.
- The pane window is **never selected**. Scrolling is done remotely via commands bound in
  the minibuffer keymap (`aperture-scroll-up` / `-down` / `-other-window`).
- If the user deletes either window mid-session, degrade silently — do not fight them.

### 3.5 consult coexistence — **RESOLVED** (source reading, confirmed on hardware in §3.5a)

Findings below are from consult `540ad1e` (2026-06-07). Line references are to that
revision and should be re-checked when consult moves.

**How consult preview actually works.**

- Every `:state` invocation — `setup`, `preview`, `exit` — is wrapped in
  `(with-selected-window (consult--original-window) …)` (consult.el:1772, 1780, 1796,
  1827). The preview target is therefore always one window, fixed for the session.
- `consult--original-window` (consult.el:949) is `(minibuffer-selected-window)` with
  fallbacks: **the window that was selected when the minibuffer was entered.**
- `consult--jump-ensure-buffer` (consult.el:1566) resolves the buffer: if it is already
  visible in *any* window, `select-window` that one; otherwise `consult--buffer-action`.
- `consult--buffer-action` funcalls `consult--buffer-display` (consult.el:535), a plain
  `defvar` whose value is **`switch-to-buffer`, not `display-buffer`**.
- Preview is driven by consult's own buffer-local `post-command-hook` (consult.el:1834)
  and re-fired on async candidate updates (consult.el:2231).

**Consequence for approach 1.** The caution I recorded was correct in substance but wrong
about the lever. `display-buffer-overriding-action` will not intercept anything, because
consult does not route preview through `display-buffer` at all. The lever is
`consult--buffer-display`, which can be let-bound for the session to a function that puts
the buffer in the aperture pane *and selects it* — selection matters, because
`consult--jump-preview` then applies `goto-char`, overlays tagged with
`'window (selected-window)`, and `consult-after-jump-hook` to whatever is selected.

**Approach 2 is dead.** Driving `:state` ourselves adds nothing: consult's own
post-command-hook already fires preview on every selection change, and the state function
is created inside `consult--read` and never exposed. There is nothing for aperture to
drive. Dropped.

**Chosen approach: reshape, don't redirect.**

Because every state call runs in `(with-selected-window (consult--original-window) …)`, and
because a window *object* survives being split, aperture can simply arrange for consult's
existing target window to be the pane:

1. On session start, save `current-window-configuration`.
2. Split the original window; put the candidate list (vertico-buffer) in the **new**
   window. The original window object persists as the remaining area — now the pane — and
   `minibuffer-selected-window` still points at it.
3. consult previews into it with no interception at all.
4. Restore the configuration on exit.

This requires **zero consult internals** and works identically for aperture's own
previewers, which render `*aperture*` into the same window. Let-binding
`consult--buffer-display` is retained as optional belt-and-braces, not as the primary
mechanism.

**Detecting who owns preview.** `consult--preview-function` (consult.el:550) is
`defvar-local` and is set in the minibuffer exactly when consult has installed preview.
consult reads it this way itself (consult.el:5626). If it is non-nil, aperture manages
geometry only and runs no previewer of its own — this is the guard against two packages
rendering into one pane.

**Known caveat.** `consult--jump-ensure-buffer` prefers *any* existing window showing the
target buffer, bypassing both the pane and `consult--buffer-display`. So if the previewed
file is already on screen elsewhere, preview lands there and the fixed geometry breaks.
Two notes: this is consult's current behaviour, so not previewing into the pane is not a
regression; and an optional `aperture-isolate-frame` (session-scoped, restored on exit)
eliminates it entirely by ensuring no other window shows the buffer. Isolation should
**not** be the default — blowing away a window layout for an `M-x` docstring is
disproportionate, and it is precisely what the prior art did wrong (minus the restore).

**Useful public hook.** `consult-after-jump-hook` (consult.el:172, defaults to `recenter`)
is called during preview as well as after the final jump — the supported place to adjust
positioning within the pane.

### 3.5a M0 results — **CONFIRMED on hardware**

Emacs 30.2.50, consult `540ad1e`, vertico with `vertico-multiform-mode` active, measured
with throwaway instrumentation since removed.

| Question | Result |
|---|---|
| Q1 `minibuffer-selected-window` survives the split | **yes** — `msw` unchanged, `eq-pane=t` |
| Q2 pane window object survives | **yes** — `still-live=t same-object=t` |
| Q3 consult previews into the pane | **yes** — `eq-pane=t` on *every* jump, `consult-line` and `consult-ripgrep`, before and after the split |
| Q4 geometry | **yes** — side-by-side, restored on exit |

Load-bearing log lines:

```
FORCED SPLIT | new=#<window 60> | pane=#<window 3> still-live=t same-object=t
post-split   | msw=#<window 3>  eq-pane=t
consult jump | rendered in #<window 3> | eq-pane=t      (×20, post-split)
```

Secondary confirmations: `consult--preview-function` is a reliable ownership signal
(`t` on consult sessions, `nil` on `execute-extended-command`); category dispatch resolved
`command`, `file`, `consult-location`, `consult-grep` correctly; our own render path and
pane restoration worked throughout.

**Reshape, don't redirect, is validated.  §3.5 is closed.**

### 3.5b Corollary: do not trust `display-buffer` for the pane

An unplanned finding, and the one that changes the design.

In one real-world configuration, `vertico-buffer-display-action` was **never consulted**,
even though `vertico-buffer--setup` demonstrably ran with the action correctly installed —
verified by advice, and the action function was never entered.  `display-buffer-alist` was
the obvious suspect (it outranks the ACTION argument) but was tested and disproved.  The
same packages in a clean `emacs -Q` behaved exactly as designed, so the cause was some
interaction in that user's configuration; it was never identified, and deliberately so —
chasing it further would have been debugging a config rather than validating a design.

**That is the point.** A `display-buffer` action is a request, and a sufficiently
opinionated configuration can ignore it silently — no error, no diagnostic, no way for the
package to tell. aperture must not rely on one for its own pane. Direct window
manipulation — `split-window` plus `set-window-buffer` on a window we hold a reference to —
worked in every run, including in the configuration where `display-buffer` did not. That
is what the pane uses, and `display-buffer-overriding-action` (top of the precedence
chain) is what places the list.

Anything that resolves this by naming one culprit is solving the wrong problem: the next
user will have a different one.

### 3.6 Preview trigger policy — **decided: live by default**

`aperture-key` defaults to `any`: the pane updates as the selection moves.

**Why.** For consult, preview is an accelerator on a picker that works without it, so
on-demand is a coherent configuration. For aperture the pane *is* the product — an
on-demand aperture is not a lighter aperture, it is a worse `embark-act` → `describe`.
Defaulting to on-demand ships the package turned off.

The counter-argument I originally recorded here — that live preview makes the first run
heavier — does not survive contact with the actual cost model. The expensive cases are
remote and huge files; the first thing a new user does is `M-x`, where the previewer is a
pure in-memory docstring lookup. Live preview is precisely what makes the package legible
in one keystroke.

The empirical evidence agrees: `consult-preview-key` has defaulted to `any` for years.
What makes that survivable is not a conservative default but the guard set in §3.3a.

**Value grammar matches `consult-preview-key` exactly**: `nil | any | KEY | (KEY…) |
(:debounce SECS any)`. Someone with `(setq consult-preview-key "M-.")` in their config
should be able to write the identical form for aperture without reading any documentation.
No inventing our own vocabulary.

**Blast radius is bounded by construction.** aperture opens the pane only for categories
present in the registry. Unlike consult, where preview applies to everything consult does,
a default-on aperture is silent for every command we have not written a previewer for.

**Escape hatch must be one keystroke**, not a config edit: `aperture-toggle` is bound in
the minibuffer keymap so a user who hits a pathological case can recover in the moment.

## 4. Built-in previewers

Priority order, roughly by how much they beat the one-line status quo:

1. `symbol` / `function` / `variable` / `command` — full docstring, signature, and source
   link. This is the flagship: marginalia can show a truncated first line, aperture shows
   the whole thing. `M-x` becomes browsable.
2. `file` / `project-file` — bounded `insert-file-contents` into a scratch buffer plus
   `set-auto-mode` and `font-lock-ensure`. Deliberately **not** `find-file`, to avoid
   triggering `find-file-hook`, LSP clients, and file-local variables on every keystroke.
3. `consult-location` (line/grep/imenu) — file content centered on the hit with the match
   highlighted.
4. `buffer` — display the live buffer directly via `:buffer`.
5. `package` — description, dependencies, README excerpt.
6. `kill-ring` — the full entry; multi-line kills are unreadable in a one-line annotation.
7. `bookmark`, `file-name-history`, `minor-mode`.

Git/magit previewers (commit diffs) are a good fit for the async path but belong in a
separate package or a later milestone.

## 5. Configuration surface

```elisp
(aperture-mode 1)                      ; global minor mode

aperture-previewer-registry            ; category → previewer
aperture-command-previewers            ; command  → previewer
aperture-height                        ; lines or frame fraction for the whole area
aperture-min-top-height                ; below this, skip the top split entirely
aperture-side                          ; 'right (default) | 'left
aperture-width                         ; pane width as a fraction or columns
aperture-key                           ; default `any'; grammar mirrors consult-preview-key
aperture-delay                         ; debounce, default 0.15 (ignored for :cost free)

;; guards — see §3.3a
aperture-partial-size                  ; 1MB; above this, read a bounded head chunk
aperture-partial-chunk                 ; 10KB
aperture-excluded-files                ; regexps; remote + gpg by default
aperture-excluded-buffers
aperture-max-count                     ; live preview buffer cap
```

Naming deliberately shadows consult's (`consult-preview-partial-size`,
`consult-preview-excluded-files`, …) so that a user who has already tuned consult can
transfer the settings by search-and-replace. The cost of an unfamiliar vocabulary is paid
by every user; the cost of a familiar one is paid by nobody.

## 6. Packaging

- `Package-Requires: ((emacs "29.1") (vertico "1.7"))`. vertico moves from soft to hard:
  §3.4 needs the candidate list in a window, and `vertico-buffer` ships in the same
  package. consult stays soft (`declare-function` + `fboundp` guards) — aperture is fully
  useful without it, and the core plus its previewers must stay testable headlessly.
- **GPL-3.0-or-later.** Required in practice for the ecosystem we interoperate with, and
  the absence of any license was a real defect in the prior art.
- Standard hygiene from commit one: library headers, `lexical-binding` on every file,
  autoload cookies, `checkdoc` + `package-lint` + byte-compile clean in CI. The prior art
  shipped 36 byte-compile warnings and a paren bug that silently disabled its own error
  handling; a clean compile is a cheap way to never repeat that.

## 7. Testing

Honest assessment: the interactive parts are hard to test in batch, so the design pushes
logic *out* of the interactive layer specifically so it can be tested.

- Unit-testable and worth testing: registry resolution order, return-value normalization
  (string/plist/function → canonical plist), generation/staleness logic, the §3.3a guards
  (partial-read chunking, exclusion matching, buffer cap), `aperture-key` grammar parsing
  including `:debounce`, window-configuration save/restore.
- Integration: a small harness that drives `completing-read` with a stub frontend, no
  vertico required — this is a reason to keep the frontend protocol.
- Manual: actual vertico/consult behavior, layout in the three window configurations.

Tests will be written to pass. (The prior art's test suite asserted that "elderberry"
contains the letter `a`, and had never been run.)

## 8. Milestones

- **M0 — spike. DONE.** See §3.5a. All four questions confirmed on hardware. The
  instrumentation was throwaway and has been removed; its findings are §3.5a and §3.5b.
- **M1 — core. DONE.** Registry, normalization, generation/staleness, cost-based
  debounce, the §3.3a guards, `aperture-key` policy, layout and restore, minibuffer
  keymap. Previewers: symbol, file, buffer, kill-ring. 27 tests, clean byte-compile,
  confirmed working on hardware.

  Deliberately deferred out of M1, and not to be mistaken for done:
  - `consult-location` previewer. Listed originally, but consult owns preview for exactly
    those sessions, so it is dead code in any default configuration. Only reachable with
    `consult-preview-key` nil. `kill-ring` was substituted.
  - `:cache-key` — documented in the contract, nothing reads it.
  - `aperture-max-count` — defined, not enforced. Moot while a single content buffer is
    reused; matters once a previewer returns `:buffer` for files.
  - The async path (`:async` / `:cancel`) is wired with generation checks but no shipped
    previewer uses it, so that code has never executed.
  - `aperture-debug`. M1 shipped a failure mode where "did not activate" and "activated
    but laid out wrong" were indistinguishable from the outside. Do this before M2.
- **M2 — consult.** `aperture-consult.el` implementing whichever approach M0 chose.
- **M3 — ship.** Remaining previewers, README, CI, MELPA recipe.

## 9. Open questions

1. Do we want the pane to survive minibuffer exit as an "inspect" buffer, or always tear
   down? (Leaning: always tear down; embark already covers the persist case.)
2. Does `display-buffer-overriding-action` hold up across the configurations that break a
   plain action (§3.5b)? It wins by Emacs' own precedence rules, and it worked where a
   plain action did not, but it has only been exercised on a handful of setups. Wants
   confirmation from more users before the README promises anything.

**Resolved:** preview trigger policy — live by default, see §3.6.
**Resolved:** consult coexistence — reshape, don't redirect, see §3.5, confirmed §3.5a.
**Resolved:** layout scope — side-by-side only, see §3.4.
**Superseded:** the earlier "vertico-buffer is not required" resolution held only while the
minibuffer-list layout was in scope. Under §3.4 it is a prerequisite. Recorded here rather
than deleted, so the reversal is visible.
