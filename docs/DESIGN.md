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
  as everything else in Emacs. **A stronger reason emerged after this was written**, and it
  is now the decisive one — see §3.4a.
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

### 3.4a Narrow windows, and why the answer is not a child frame — **fixed**

Reported after a month of use: with the frame already split into columns, aperture splits
one of them again and both halves become too narrow to read.

Measured on a 200-column frame, by pre-existing column count:

| columns | pane width, splitting in place | pane width, taking the frame |
|---|---|---|
| 1 | 100 | 100 |
| 2 | 50 | 100 |
| 3 | **32** | 100 |
| 4 | **23** | 100 |

At one or two columns there is no problem. At three the pane is 32 columns, which is not
enough to read code in. The cause is structural: **aperture carves its area out of exactly
one window, and that window is as wide as the user's layout left it.**

**Why the pane cannot simply be moved to a roomier window.** §3.4's split ordering exists
because consult previews into `minibuffer-selected-window` (§3.5). The pane *is* that window
object. Any fix that puts the pane somewhere else — another window, a side window, a child
frame — breaks that, and preview lands back in the user's original buffer window.

**This is what rules out posframe**, and it is a much harder objection than the four listed
in §3.4. A child frame's window can never be `minibuffer-selected-window`, which is a window
in the parent frame, fixed before the child frame exists. Making preview work there would
mean intercepting every consult preview path — `consult--jump-preview`,
`consult--file-preview`, `consult--buffer-preview`, theme preview, and whatever is added
next — which is exactly the *redirect* approach §3.5 rejected after source reading and
hardware confirmation. §3.5c is what one such interception costs to get right; the posframe
version is that cost, repeated, forever. TTY support is the second reason and would be
sufficient on its own.

**The fix: give the session the frame, when and only when it needs it.** If the pane would
come out under `aperture-min-pane-width` (default 40), `delete-other-windows` runs on the
original window before the usual splits, and the saved window configuration is restored on
exit. The original window object survives — it is the one `delete-other-windows` keeps — so
invariant 1 holds unchanged, and every split below it is identical to the single-window case.

Confirmed in batch across 1–4 columns: expansion fires only at 3+, the pane is the same
window object throughout, and the exact original window count comes back on restore.

- **Sidebars survive.** `delete-other-windows` honours the `no-delete-other-windows`
  parameter, which is what treemacs, dired-sidebar and friends set. Verified: a sidebar
  carrying it stays, and the pane still gets 85 of 200 columns. A side window that does
  *not* set it is deleted and comes back from the saved configuration.
- **Restore has to change with it.** The surgical restore in `aperture--restore` cannot
  bring back deleted windows, so an expanded session restores from
  `current-window-configuration` instead. The gentler path is kept for every other session,
  since §3.4 wants to avoid fighting vertico-buffer's teardown where it can.
- **Why a width threshold rather than a switch.** The complaint is about width, and the
  table above shows width is what actually varies. A single-window user sees no change at
  all; `nil` opts out; a value above the frame width makes it unconditional.
- **The trigger needs two conditions, not one** — corrected after the first version shipped
  with only the first. The pane must be too narrow, *and* deleting siblings must be capable
  of fixing it. Only windows placed **beside** the original make it narrow. Windows stacked
  above or below (an ordinary `C-x 2`) are already full width, so the first version deleted
  them and widened the pane by exactly nothing. The test is
  `(< (window-total-width win) (window-total-width (frame-root-window win)))`, which also
  subsumes the sole-window case. **`window-total-width`, not `window-width`**: once a frame
  is split at all its root window is an *internal* window, and `window-width` accepts only
  live ones — the obvious spelling signals an error precisely when the feature fires.
- **`delete-other-windows` selects the window it keeps.** A session is built with the
  minibuffer selected, so calling it bare hands the selection to the pane's window and the
  user's next keystroke goes into the previewed buffer instead of the prompt. Wrap it in
  `save-selected-window`. This shipped broken and was reported from use; the geometry was
  perfect throughout, which is exactly why the tests missed it — **they asserted widths and
  window counts and never once asserted which window was selected.** There is now a test
  that selects the minibuffer, builds a layout, and asserts the minibuffer is still
  selected; it was confirmed to fail without the fix. Teardown was checked for the mirror
  image and is fine: `set-window-configuration` restores the selected window from the saved
  configuration, which was the minibuffer.
- **The name promises more than it delivers**, and is kept only because the alternatives are
  worse. It is a trigger, not a floor: when the frame itself is too narrow, or the window is
  the only one, nothing can be done and the pane stays narrow. The docstring says so.

**The tradeoff, stated plainly**, because it is a real one: during the session you lose
sight of your other windows. What you keep is the buffer you invoked completion from, which
stays visible in the top window — that is the context the design already decided was worth
reserving space for. Everything else is restored on exit. This is also what telescope does,
and aperture is explicitly modelled on it.

### 3.4b The child-frame layout — **shipped, opt-in** (§3.4a's objection was wrong)

§3.4a rejected this because preview would mean "intercepting every consult preview path …
repeated, forever". That is wrong. In consult `20260731.2051`, `consult--original-window`
(consult.el:950) is a function recomputed on every preview — so there is no variable to
rebind, which is the half §3.4a got right — but all four call sites (1770, 1778, 1794,
1825) wrap in `with-selected-window (consult--original-window)` and then act on
`(selected-window)`. One `:around` advice covers every path. The cost is bounded; §3.4a's
other objections stand on their own.

`aperture-display` selects the layout and defaults to `window`. `child-frame` puts the
whole UI — prompt, candidate list and pane — in a frame aperture owns, and degrades to
`window` with a log line when `(or (display-graphic-p) (featurep 'tty-child-frames))` is
nil.

**The gate was whether an active minibuffer survives the frame hop.**
`with-selected-window` on a window in another frame selects that *frame*, and
`minibuffer-follows-selected-frame` defaults to `t`. It does not fire here: a child frame
created with `(minibuffer . <parent's minibuffer-window>)` has no minibuffer to receive
one. Confirmed with the default `t`, along with the rest of the layout, by
`dev/spike-posframe.el` — 29 checks on Emacs 30.2.50 / macOS. That file ships because
batch cannot reach any of this and it is the only executable record.

**Two things get simpler:**

- §3.5c's defect does not arise. `consult--jump-ensure-buffer` calls `get-buffer-window`
  with no ALL-FRAMES argument, and during preview the selected frame is the child frame,
  so the parent's window showing the same buffer is invisible to it. The adapter stays for
  the window layout and is harmless here.
- §3.4a's apparatus is unnecessary. The parent's windows are never touched: no
  `delete-other-windows`, no saved configuration, no `save-selected-window` trap. Teardown
  is `delete-frame`, and the user keeps *all* their windows as context rather than one.

**It is not `vertico-posframe` integration.** That package owns its frame's single window
and re-fits it on every `vertico--display-candidates`; a split made inside it would be
fought on every keystroke. aperture owns its own frame and stands *down for*
vertico-posframe instead — per-session, by advising `vertico-posframe-mode-workable-p`,
never by touching the global mode, since `cl-defmethod` `&context` re-resolves per call.
The cost is that a user's `vertico-posframe-*` settings do not shape an aperture session.

**Costs, permanent:**

- **No CI coverage, ever.** Only the geometry is reachable in batch; the layout, the
  redirect and the rendering are hardware checks (TODO.md).
- **It is a redirect.** One function rather than many, but still aperture reaching into
  consult rather than arranging geometry and standing back, which is what §3.5 chose. The
  window layout keeps that property; this one trades it away deliberately.
- **Verified on emacs-mac 30.2.50 / macOS only.** X and pgtk child frames have diverged
  historically.

Two traps found the hard way, both now invariants in TODO.md: `abort-recursive-edit`
arrives as a `quit` signal, which `ignore-errors` does not catch; and
`minibuffer-selected-window` is nil inside any `with-selected-window`, on any frame.

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

### 3.5c Does `aperture-consult.el` need to exist? — **yes, for exactly one reason** (shipped)

M2 was left open as "create it only if something beyond the ownership check turns up".
Something did, and it is not what M2 anticipated.

**The defect.** §3.5's "known caveat" — `consult--jump-ensure-buffer` prefers *any* window
already showing the target buffer — is not an edge case under aperture. Aperture
**manufactures** a second window showing the original buffer: the top window is a split of
the pane's window, so both show the same buffer. Sequence during `consult-ripgrep` across
files:

1. Pane shows B (the original buffer). Top window shows B.
2. First hit is in file F → pane switches to F. Correct.
3. Next hit is back in B. `(eq (current-buffer) buf)` now fails, so consult falls to
   `(get-buffer-window B)` → **the top window** → `select-window`. Preview lands there:
   point moves, `consult-after-jump-hook` recenters it, the match overlay is drawn in it,
   and the pane is left showing a stale F.

Confirmed in batch against consult `540ad1e`, reproducing aperture's exact window
arrangement. Not theoretical.

**Scope of the blast radius.** Every position-preview command routes through this one
function: `consult--jump-preview` ← `consult--jump-state` ← `consult--location-state`, plus
`consult-xref`, `consult-compile`, `consult-flymake`, `consult-imenu-multi`,
`consult-info`, `consult-register`, `consult-org`, `consult-global-mark`. Single-buffer
commands (`consult-line`, `consult-outline`) escape only because the pane still shows the
target, so branch 1 short-circuits. The multi-file commands — the ones the pane is most
useful for — all hit it.

**No fix exists outside consult's internals.** Tested and rejected:

| Attempt | Result |
|---|---|
| `set-window-dedicated-p` on the top window | `get-buffer-window` ignores dedication |
| `no-other-window` parameter | ignored too; it only affects `next-window`/`other-window` |
| Let-bind `consult--buffer-display` (§3.5's belt-and-braces) | never reached — the offending branch is `select-window`, not `consult--buffer-action` |
| Don't create the top window | it is the feature; and consult sessions are where it matters most |
| Show an indirect clone in the top window | works in principle, but puts a second visible buffer in the user's buffer list to fix a window bug |

**The fix.** An `:around` advice on `consult--jump-ensure-buffer`: when an aperture session
is active and the selected window is its pane, put the target in the pane via
`consult--buffer-action` and return t; otherwise call through unchanged. Validated in the
same harness — preview lands in the pane, and with no session the stock behaviour is
byte-for-byte preserved.

Its safety argument is that it does not invent a path: it forces the branch consult already
takes for any file not currently visible, so preview-buffer lifecycle, `norecord`
behaviour, and cleanup are identical to what consult does the majority of the time.

**Therefore `aperture-consult.el` exists, and holds only this.** Explicitly *not* in it:

- `aperture--consult-owns-p` stays in core. The core's decision not to run its own previewer
  must work when the adapter is not loaded at all — it is a `bound-and-true-p` on a symbol,
  costing nothing, and moving it would make correctness depend on an optional file.
- Let-binding `consult--buffer-display` is **dropped**, not deferred. §3.5 kept it as
  optional insurance; `consult--buffer-action` already runs inside
  `with-selected-window` on the pane, so it insures nothing.
- **`aperture-isolate-frame` is retired.** It was §3.5's mitigation for this same caveat.
  The advice bypasses `get-buffer-window` entirely, which fixes the pre-existing-window
  case too — and does it without blowing away the user's layout. A planned option that a
  better fix makes unnecessary is a good trade.

**How the adapter gets loaded.** `aperture--setup` calls `aperture--consult-arrange` on
every completion session, which installs the advice the first time it finds consult loaded.
The obvious `with-eval-after-load 'consult` was tried first and is worse than it looks:
those entries accumulate, are never removed, and outlive `aperture-mode` being turned off —
so the hook body has to re-check the mode, and enable/disable stop being symmetric. Polling
costs one `featurep` per session, `require` on a loaded feature is that same test again, and
`advice-add` will not add the same advice twice. `package-lint` flags `with-eval-after-load`
in packages; here it was pointing at something real rather than at a style preference.

With consult absent, nothing is advised. The adapter has no load-time dependency on it
either, which is what lets the test suite — which runs with no `DEPS` at all — cover its
decision logic.

**Verified with consult loaded**, the real advice on the real function, reproducing the
arrangement above: preview lands in the pane, and with no session consult's behaviour is
unchanged. What batch cannot reach is a live minibuffer, so the end-to-end symptom during
an actual `consult-ripgrep` is a manual check — see `dev/try.el`.

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
   The two categories need **different previewers**, for the reason in §4.3.
3. `consult-location` (line/grep/imenu) — file content centered on the hit with the match
   highlighted.
4. `buffer` — display the live buffer directly via `:buffer`.
5. `package` — metadata plus the package's own `Commentary`. **Not** the archive README:
   `describe-package` fetches that over the network, which a previewer running on every
   selection change may not do. Resolution reads `package-alist`,
   `package-archive-contents` and `package--builtins` directly rather than calling
   `package-get-descriptor`, which runs `package-initialize` as a side effect and still
   does not cover built-ins — much of what `describe-package` is actually pointed at.
6. `kill-ring` — the full entry; multi-line kills are unreadable in a one-line annotation.
7. `bookmark` — the target file, centred on the stored position. A bookmark carrying a
   `handler` is shown as its raw record instead: resolving it means running that handler,
   which visits the target for real.

Git/magit previewers (commit diffs) are a good fit for the async path but belong in a
separate package or a later milestone.

### 4.1 Two categories that do not exist — **the dispatch gap** (shipped)

`package` and `bookmark` were nearly shipped as dead code. `describe-package`,
`package-install` and `bookmark-jump` all call `completing-read` on a bare list of strings
and **declare no completion category at all** — confirmed by reading their interactive
forms. aperture dispatches on category, so neither previewer could ever have fired.

marginalia has the same problem and solves it with `marginalia-classifiers`, installed as
`:before-until` advice on `completion-metadata-get`. aperture calls that same function, so
**where marginalia-mode is on, aperture inherits the classification for free** and never
reaches any fallback of its own. That is worth stating because it is not obvious and it is
load-bearing: most of aperture's audience runs marginalia, and for them nothing further is
required.

For everyone else there is `aperture-prompt-categories`, consulted only when the metadata
gives nothing: two regexps, covering exactly the two categories aperture can preview. It is
deliberately not a copy of marginalia's eighteen. Duplicating a classifier is a maintenance
cost; duplicating the two lines of it that make shipped code reachable is not.

Note which previewers were *never* at risk: `symbol` (`read-extended-command` declares
`command`), `file` (`read-file-name` declares `file`), `buffer`, `kill-ring`. Only the
categories added in M3 needed this, which is why it did not surface until M3.

### 4.2 Why there is no `imenu` previewer

It would be dead code twice over. `consult-imenu` sets `:category 'imenu` **and** a
`:state` built on `consult--jump-preview` — consult owns preview there, exactly as it does
for `consult-location` (deferred in §8 for the same reason). And plain `M-x imenu` resolves
a candidate name through `imenu--index-alist`, which is buffer-local to the *original*
buffer and not reachable from the minibuffer where previewers run.

Looking for it surfaced the real defect in the neighbourhood: `imenu` was not in
`aperture-consult-categories` either, so `consult-imenu` opened **no pane at all** and
previewed into the plain original window. The same was true of `consult-flymake-error`,
`consult-info`, `org-heading` and `multi-category` (`consult-buffer`). All five are now
listed. The membership test is precise: consult passes a jump-preview `:state` for that
category, *and* aperture has no previewer of its own. Categories consult previews but
aperture also handles — `file`, `buffer`, `bookmark`, `kill-ring` — stay out, because those
activate on their own previewer and hand over at run time via `aperture--consult-owns-p`.

One entry is a compromise. `imenu` is the only one a non-consult command can also produce,
since marginalia classifies plain `M-x imenu` into it; the pane then opens with nothing to
render. That is the lesser cost — `consult-imenu` previewing into the wrong window is a
visible defect, an idle pane is not.

### 4.3 `project-file` is not `file` — **fixed**

Reported from real use: `projectile-find-file` showed `Preview unavailable: not readable`
for every candidate in one repository, and worked perfectly in another.

`project-file` candidates are relative to the **project root**. `file` candidates are
relative to `default-directory`. aperture had both categories pointing at
`aperture-preview-file`, which expands against `default-directory` — so a candidate
`src/config.el`, selected from a buffer in `lib/backend/`, was resolved as
`lib/backend/src/config.el` and refused by the readability guard.

The two directories coincide exactly when completion was started from a buffer sitting at
the project root. That is why it looked correct in the aperture repository, where everything
you would edit is at the top level, and failed in a deeply nested one. **A bug that
reproduces only in repositories with subdirectories is not a bug anyone would have thought
to test for**, which is the actual lesson: the flat repository you develop in is not a
representative sample.

`aperture-preview-project-file` resolves the root and delegates, in this order:

1. **The prompt**, when `project-find-file` or `project-dired` names the root in it. That
   is the root which *produced* the candidates, so it outranks any re-derivation. The regexp
   is marginalia's.
2. **`projectile-project-root`**, when projectile is loaded. projectile has its own notion
   of a root and generated its own candidates from it; when projectile is asking, its
   answer is the one that matches.
3. **`project-current`** / `project-root`.
4. Failing all of those, `default-directory` — the old behaviour, which is right whenever
   the root cannot be established.

Absolute candidates are passed straight through: project *directories* are reported under
this category too.

Root resolution runs in the minibuffer, whose `default-directory` is inherited from wherever
completion started. That is stable for the session and, importantly, unaffected by whatever
the pane is currently displaying — the trap `aperture--active-session` documents for
consult. marginalia resolves the same root the same way, from inside the minibuffer buffer,
which is good evidence the assumption holds.

## 5. Configuration surface

```elisp
(aperture-mode 1)                      ; global minor mode

aperture-previewer-registry            ; category → previewer
aperture-command-previewers            ; command  → previewer
aperture-height                        ; lines or frame fraction for the whole area
aperture-min-top-height                ; below this, skip the top split entirely
aperture-side                          ; 'right (default) | 'left
aperture-width                         ; pane width as a fraction or columns
aperture-min-pane-width                ; below this, take the frame; see §3.4a
aperture-key                           ; default `any'; grammar mirrors consult-preview-key
aperture-delay                         ; debounce, default 0.15 (ignored for :cost free)
aperture-consult-categories            ; open the pane for geometry, let consult render
aperture-prompt-categories             ; prompt → category fallback; see §4.1

;; guards — see §3.3a
aperture-partial-size                  ; 1MB; above this, read a bounded head chunk
aperture-partial-chunk                 ; 10KB
aperture-excluded-files                ; regexps; remote + gpg by default
aperture-excluded-buffers
aperture-max-count                     ; live preview buffer cap

aperture-debug                         ; log to *aperture-log*; see §7.1

;; child-frame layout — see §3.4b.  `aperture-height' and `aperture-min-top-height'
;; do not apply there, there being no top window; `aperture-side', `aperture-width'
;; and `aperture-min-pane-width' do, the last by widening the frame rather than
;; taking the parent's windows.
aperture-display                       ; 'window (default) | 'child-frame
aperture-child-frame-width             ; parent fraction, or columns
aperture-child-frame-height            ; parent fraction, or lines
aperture-child-frame-position          ; 'center | 'top | (X . Y) | function
aperture-child-frame-border-width      ; 0 for none
aperture-child-frame-parameters        ; extra frame parameters, applied last
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

### 7.1 Diagnosis: `aperture-debug`

Everything above covers what can be asserted in batch. What it cannot cover is the class of
bug M1 actually shipped: **a session that never activated and a session that activated but
laid its windows out wrong present identically** — the preview is not where you expected,
with no error, no message, and nothing in `*Messages*`. Diagnosing one instance of that
cost several round trips of instrumenting a live Emacs by hand. That is a design defect in
the package, not bad luck, and the fix belongs in the package.

`aperture-debug` writes to `*aperture-log*`. Lines are timestamped and tagged with
`minibuffer-depth`, so recursive sessions stay separable. It records exactly the decision
points where aperture can silently do nothing:

| Line | Answers |
|---|---|
| `setup … no session: REASON` | Did a session start, and if not, *which* of the ways to decline was taken — `aperture-key` nil, no frontend, unknown category, no category at all |
| `setup … previewer=` | Which previewer the registry resolved, or that the category is consult-owned |
| `layout pane= list= top=` | Where the three windows actually landed, with dimensions |
| `layout top split skipped` | The frame was too short for `aperture-min-top-height` — a silent geometry change |
| `list placed in` / `list not placed` | Whether the `display-buffer-overriding-action` interception fired (§3.5b) |
| `consult took/released preview` | Ownership transitions, logged on change only |
| `sched` / `run` / `render` / `drop … superseded` | Each dispatch with its generation, so debounce and staleness are visible rather than inferred |

Two properties worth preserving. It is **inert when off** — no buffer is created, nothing is
formatted; there is a test asserting exactly that, because a debug facility that costs
something when disabled gets disabled permanently. And `aperture-show-log` **turns logging
on** before displaying the buffer, so the instruction in a bug report is one command rather
than a customize step plus a buffer name.

The negative lines matter more than the positive ones. "Nothing happened" is the failure
being diagnosed, so the log has to be loud precisely where the code is quiet.

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
- **M1.5 — `aperture-debug`. DONE.** See §7.1. Taken before M2 because M1 shipped a
  failure mode where "did not activate" and "activated but laid out wrong" were
  indistinguishable from the outside.
- **M2 — consult. DONE.** `aperture-consult.el`: one `:around` advice on
  `consult--jump-ensure-buffer`, and nothing else. §3.5c. Fixed a confirmed defect in
  shipped M1 behaviour, so it was not optional. 39 tests. Outstanding: the manual
  `consult-ripgrep` confirmation batch cannot perform.
- **M3 — ship. DONE.** `package` and `bookmark` previewers (§4), the dispatch gap they
  exposed (§4.1), five missing entries in `aperture-consult-categories` (§4.2), README, CI,
  MELPA recipe. 52 tests.

  No `imenu` previewer — §4.2 for why not, which is the more useful finding.

  CI runs the same `make` targets a developer runs, via a generated `.deps.mk`. Two claims
  §6 had been making without evidence are now checked: `byte-compile-error-on-warn` (batch
  byte-compilation exits 0 on warnings, so "clean compile" was unverified) and
  `package-lint`, which had never been run at all. It was clean but for one warning, and
  that warning was correct — see the `with-eval-after-load` note in §3.5c.

  Still owed, and not blocked on anything but a person at a keyboard: the manual
  `consult-ripgrep` check from M2, plus the two new panes (`describe-package`,
  `bookmark-jump`). `dev/try.el` sets all three up.

  **First field report** (`projectile-find-file` unreadable in a nested repository) landed
  within a day and is fixed: §4.3. It was a real defect in M1's registry, invisible in every
  repository the package had been developed in.

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
