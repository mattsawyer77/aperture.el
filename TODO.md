# aperture — next steps

Working notes. The reasoning behind every decision below is in
[docs/DESIGN.md](docs/DESIGN.md); section numbers are cited rather than repeated.

## Where things stand

- **M0 (spike) — done.** Layout and consult-coexistence questions confirmed on hardware.
  §3.5a. Instrumentation removed; findings kept.
- **M1 (core) — done.** Registry, dispatch, staleness, debounce, guards, layout, session
  lifecycle, keymap, four previewers. 27 tests, clean byte-compile, working on hardware.
  §8.
- Initial commit `68c8d6f` on `main`. No remote yet.

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

## Next up

### 1. `aperture-debug` — do this before M2

M1 shipped a failure mode where "did not activate" and "activated but laid out wrong" were
indistinguishable from the outside, which cost several round trips to diagnose. Wanted: an
opt-in log of session start (category, command, resolved previewer, activate decision),
layout results (pane/list/top windows), consult ownership, and each preview dispatch with
its generation. Roughly what the M0 spike's log did.

### 2. M2 — consult adapter

Currently one line in core (`aperture--consult-owns-p` testing
`consult--preview-function`). Open whether `aperture-consult.el` needs to exist at all;
create it only if something beyond that check turns up. §3.5.

### 3. M3 — ship

Remaining previewers (`package`, `bookmark`, `imenu`), README, CI, MELPA recipe. §8.

## Deferred from M1 — not done, do not mistake for done

- **`consult-location` previewer.** Listed in the original M1 scope. consult owns preview
  for exactly those sessions, so it is dead code in any default configuration — only
  reachable with `consult-preview-key` nil. `kill-ring` was substituted.
- **`:cache-key`** — documented in the §3.3 contract, nothing reads it.
- **`aperture-max-count`** — defined, not enforced. Moot while a single content buffer is
  reused; matters once a previewer returns `:buffer` for files.
- **Async path** (`:async` / `:cancel`) — wired through `aperture--deliver` with generation
  checks, but no shipped previewer uses it, so that code has never executed. First async
  previewer should be treated as also testing this machinery.
- **On-demand `aperture-key`** — the `KEY` / `(KEY...)` forms parse and bind
  `aperture-preview-now`, but this path has not been exercised interactively.

## Open questions

Full list in §9. The live ones:

1. Should the pane survive minibuffer exit as an "inspect" buffer? Leaning no — embark
   already covers the persist case.
2. Does `display-buffer-overriding-action` hold up across configs that break a plain
   action? It wins by Emacs' precedence rules and worked where a plain action did not, but
   has only been tried on a handful of setups. Wants more evidence before the README
   promises anything.

## Building

```
make compile      # needs DEPS
make test         # deliberately needs nothing
make try          # interactive smoke test in emacs -Q; needs DEPS
```

`DEPS` points at vertico/consult checkouts. Set it in `local.mk` (untracked, already
present on this machine) or pass it on the command line.
