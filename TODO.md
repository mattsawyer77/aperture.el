# aperture — next steps

Working notes. The reasoning behind every decision below is in
[docs/DESIGN.md](docs/DESIGN.md); section numbers are cited rather than repeated.

## Where things stand

- **M0 (spike) — done.** Layout and consult-coexistence questions confirmed on hardware.
  §3.5a. Instrumentation removed; findings kept.
- **M1 (core) — done.** Registry, dispatch, staleness, debounce, guards, layout, session
  lifecycle, keymap, four previewers. 27 tests, clean byte-compile, working on hardware.
  §8.
- **M1.5 (`aperture-debug`) — done.** `*aperture-log*`, `M-x aperture-show-log`, on by
  default in `make try`. §7.1.
- **M2 (consult adapter) — done.** One `:around` advice on
  `consult--jump-ensure-buffer`, fixing a confirmed defect in M1 behaviour. §3.5c.
- **M3 (ship) — done.** `package` and `bookmark` previewers, the dispatch gap they
  exposed (§4.1), five missing `aperture-consult-categories` entries (§4.2), README, CI,
  MELPA recipe. 52 tests.
- On `main`. **No remote yet** — the CI badge and every install snippet in the README
  point at `github.com/msawyer/aperture.el`, which does not exist. Creating it is the one
  thing standing between here and a MELPA submission.

## Manual checks owed

Batch cannot reach a live minibuffer, so these are the claims no test covers. `make try`
sets all three up and says what failure looks like; `aperture-debug` is already on there.

1. **`consult-ripgrep`** matching in both the current buffer and another file — every hit
   must preview in the pane, not scroll the top window. This is the M2 defect (§3.5c); the
   mechanism is verified against real consult in batch, the live path is not.
2. **`describe-package`** — must open a pane at all. `make try` has no marginalia, so this
   exercises `aperture-prompt-categories` specifically (§4.1). No pane means the fallback
   is broken, and the log will say `no completion category`.
3. **`bookmark-jump`** — same, plus the file-and-position rendering. Needs a bookmark to
   exist first.

## Invariants — break these and it fails silently

Each of these cost real debugging time. None of them announce themselves when violated.

1. **Split ordering** (§3.4). consult previews into `minibuffer-selected-window`, so that
   window object must end up as the pane. Split `'above` first (leaves it as the bottom
   strip), then toward `aperture-side` (leaves it on the pane side). Any other order hands
   the pane role to a window consult will never touch, and preview "goes to the wrong
   place" with no error.
2. **Session start is `:before` advice on `vertico--setup`, not a hook** (§3.1).
   `completing-read-default` sets `minibuffer-completion-table` from inside its own
   `minibuffer-with-setup-hook` lambda. Any `minibuffer-setup-hook` entry early enough to
   precede vertico-buffer is also too early to see the completion category — so aperture
   never activates, and what you see is stock vertico-buffer behaviour.
3. **Never place the pane with `display-buffer`** (§3.5b). An action is a request; a
   sufficiently opinionated config can ignore it silently. Pane uses `split-window` +
   `set-window-buffer` on a held reference. List placement uses
   `display-buffer-overriding-action`, which outranks everything.
4. **`vertico--index` cannot test whether vertico is active.** It is `defvar-local` with a
   default of -1, which is non-nil. Use `vertico--input`, as vertico's own
   `vertico--command-p` does. See `aperture-vertico--active-p`.
5. **The core must keep loading without vertico or consult** — and so must
   `aperture-consult.el`, which uses `declare-function` rather than `require`. `make test`
   deliberately passes no `DEPS`; that is what stops it regressing, and it is the only
   reason the adapter's logic is testable at all. CI runs it that way too.
6. **The top window shows the same buffer as the pane**, being a split of it. That is what
   makes consult preview into the wrong window without `aperture-consult.el` (§3.5c). Any
   future layout change that puts more windows on screen has to be re-checked against
   `consult--jump-ensure-buffer`, which prefers *any* window already showing the target.
7. **Registering a previewer does not make it reachable** (§4.1). Plenty of built-in
   commands call `completing-read` on a bare list and declare no category at all —
   `describe-package` and `bookmark-jump` among them — so a registry entry for them is dead
   code. Before adding a previewer, check what the command's completion table actually
   reports; do not assume a category exists because marginalia annotates the command, since
   marginalia may be *inferring* it. And check the reverse too: if consult drives preview
   for that category, the entry belongs in `aperture-consult-categories`, not the registry.

## Diagnosing anything below

Set `aperture-debug` (or just `M-x aperture-show-log`, which turns it on) before
reproducing. §7.1. The log is loudest exactly where the code is silent: which reason a
session declined to start, where the three windows landed, whether the list interception
fired, when consult took ownership. Reach for it before instrumenting by hand — that is
what it was built to replace.

## Next up

Nothing is blocking. In rough order of value:

1. **Create the GitHub remote**, push, confirm CI is green on 29.1 (the declared floor has
   never actually been compiled against), then submit the MELPA recipe from the README.
2. **Work the manual checks above.**
3. Pick off items from "Deferred from M1" as they stop being hypothetical. The async path
   is the one with real risk: it has never executed.

## Deferred from M1 — not done, do not mistake for done

- **`consult-location` previewer.** Listed in the original M1 scope. consult owns preview
  for exactly those sessions, so it is dead code in any default configuration — only
  reachable with `consult-preview-key` nil. `kill-ring` was substituted.
- **`:cache-key`** — documented in the §3.3 contract, nothing reads it.
- **`aperture-max-count`** — defined, not enforced. Moot while a single content buffer is
  reused; matters once a previewer returns `:buffer` for files.
- **Async path** (`:async` / `:cancel`) — wired through `aperture--deliver` with generation
  checks, but no shipped previewer uses it, so that code has never executed. First async
  previewer should be treated as also testing this machinery; the `async gen=N dispatched`
  and `drop gen=N superseded` log lines exist for exactly that.
- **On-demand `aperture-key`** — the `KEY` / `(KEY...)` forms parse and bind
  `aperture-preview-now`, but this path has not been exercised interactively.

## Open questions

Full list in §9. The live ones:

1. Should the pane survive minibuffer exit as an "inspect" buffer? Leaning no — embark
   already covers the persist case.
2. Does `display-buffer-overriding-action` hold up across configs that break a plain
   action? It wins by Emacs' precedence rules and worked where a plain action did not, but
   has only been tried on a handful of setups. Wants more evidence before the README
   promises anything — and the evidence is now collectable, since a config that defeats it
   logs `list not placed` rather than looking like a session that never started.

## Building

```
make check        # compile + test + lint + package-lint -- exactly what CI runs
make deps         # install vertico/consult/package-lint into .deps/; needs network
make compile      # warnings are errors
make test         # deliberately needs nothing on the load path
make try          # interactive smoke test in emacs -Q; needs DEPS
```

`DEPS` points at vertico/consult checkouts. Set it in `local.mk` (untracked), or run
`make deps`, which writes `.deps.mk` and *appends* — the two coexist, and `make deps` never
touches `local.mk`.

`make package-lint` needs `make deps` to have run: it wants package-lint itself, and the
archive contents it validates the dependency declarations against.
