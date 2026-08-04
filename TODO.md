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
  default in `make try`. 33 tests. §7.1.
- On `main`. No remote yet.

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
5. **The core must keep loading without vertico or consult.** `make test` deliberately
   passes no `DEPS`; that is what stops it regressing.

## Diagnosing anything below

Set `aperture-debug` (or just `M-x aperture-show-log`, which turns it on) before
reproducing. §7.1. The log is loudest exactly where the code is silent: which reason a
session declined to start, where the three windows landed, whether the list interception
fired, when consult took ownership. Reach for it before instrumenting by hand — that is
what it was built to replace.

## Next up

### 1. M2 — consult adapter — **scope settled, not yet implemented**

`aperture-consult.el` does need to exist, and holds exactly one thing: an `:around` advice
on `consult--jump-ensure-buffer`. **§3.5c** has the full argument, the batch reproduction,
and the four alternatives that were tested and rejected.

Short version: aperture manufactures a second window showing the original buffer (the top
window is a split of the pane), and consult prefers *any* window already showing a preview
target. So during `consult-ripgrep` across files, hits in the original buffer preview into
the top window — point moves there, it recenters, the match highlights there — while the
pane sits stale. This is a real defect in shipped M1 behaviour, not a nicety, and it
affects every multi-file consult command.

Not in the adapter, and each for a stated reason in §3.5c: `aperture--consult-owns-p`
stays in core; the `consult--buffer-display` let-binding is dropped as insuring nothing;
`aperture-isolate-frame` is retired, because this fix subsumes what it was for.

### 2. M3 — ship

Remaining previewers (`package`, `bookmark`, `imenu`), README, CI, MELPA recipe. §8. The
README's troubleshooting section is one line now: run `M-x aperture-show-log`.

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
make compile      # needs DEPS
make test         # deliberately needs nothing
make try          # interactive smoke test in emacs -Q; needs DEPS
```

`DEPS` points at vertico/consult checkouts. Set it in `local.mk` (untracked, already
present on this machine) or pass it on the command line.
