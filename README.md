# aperture

[![CI](https://github.com/mattsawyer77/aperture.el/actions/workflows/ci.yml/badge.svg)](https://github.com/mattsawyer77/aperture.el/actions/workflows/ci.yml)

A preview pane for Emacs completion. Telescope-style two-pane UX, on vertico.

`aperture` differs from [`marginalia`](https://github.com/minad/marginalia), which annotates 
each candidate with one line of context. Instead, `aperture` uses a vertically split pane 
containing arbitrary, multi-line, fontified context for the selected candidate, dispatched 
on the candidate's completion category, and working for any `completing-read`.

```
+---------------------------------------+
|  original buffer - stays visible      |
+-------------------+-------------------+
|  candidate list   |  preview pane     |
+-------------------+-------------------+
|  minibuffer                           |
+---------------------------------------+
```

`M-x` shows whole docstrings. `C-x C-f` shows file contents, fontified. `consult-line` and
`consult-ripgrep` preview into the same pane they already would have — aperture arranges the
geometry and gets out of the way.

**Status: alpha.** Working and tested, but not yet on MELPA and not yet used by anyone but
myself. The design and its open questions are written down in
[docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- Emacs 29.1+
- [vertico](https://github.com/minad/vertico), including `vertico-buffer` (same package)
- For the optional child-frame layout, a graphical Emacs. Everything else works on a
  TTY.
- [consult](https://github.com/minad/consult) — optional. aperture is fully useful without
  it; with it, aperture's pane becomes consult's preview window.
- [marginalia](https://github.com/minad/marginalia) — optional, recommended. Not required
  for anything to work, but it classifies several commands that declare no completion
  category, which is what makes the `package` and `bookmark` previews fire on
  `describe-package` and `bookmark-jump`. See [§4.1](docs/DESIGN.md).

## Installation

Not on MELPA yet. Until it is:

```elisp
;; use-package's :vc keyword needs Emacs 30; on 29 use M-x package-vc-install
;; with the same URL.
(use-package aperture
  :vc (:url "https://github.com/mattsawyer77/aperture.el" :rev :newest)
  :after vertico
  :config (aperture-mode 1))
```

or with straight:

```elisp
(use-package aperture
  :straight (aperture :type git :host github :repo "mattsawyer77/aperture.el")
  :after vertico
  :config (aperture-mode 1))
```

`aperture-mode` is global. Turning it on is the whole setup; everything below is optional.

<details>
<summary>MELPA recipe (for when it is submitted)</summary>

```elisp
(aperture
 :fetcher github
 :repo "mattsawyer77/aperture.el"
 :files ("aperture.el" "aperture-previewers.el" "aperture-vertico.el"
         "aperture-consult.el" "aperture-child-frame.el"))
```

Recipes live in [melpa/melpa](https://github.com/melpa/melpa), not here.
</details>

## Configuration

```elisp
(setq aperture-height 0.5        ; whole area: lines, or a fraction of the frame
      aperture-width 0.5         ; pane width within that area
      aperture-side 'right       ; or 'left
      aperture-min-pane-width 40 ; below this, take the frame for the session
      aperture-key 'any          ; when to preview; grammar mirrors consult-preview-key
      aperture-delay 0.15)       ; debounce (ignored for cheap previewers)
```

`aperture-key` takes the same values as `consult-preview-key`, deliberately, so settings
transfer verbatim: `nil`, `any`, a key, a list of keys, or `(:debounce SECS any)`.

If your frame is already split into columns, the pane can come out too narrow to read. When
it would fall under `aperture-min-pane-width`, the session takes the whole frame instead and
restores your window configuration on exit; sidebars carrying `no-delete-other-windows`
(treemacs, dired-sidebar) are left alone. Set it to `nil` to always split in place, however
narrow, or above your frame width to always take the frame. [§3.4a](docs/DESIGN.md).

In the minibuffer, `C-M-v` and `C-M-S-v` scroll the pane without leaving the prompt.

Guards, all customizable: `aperture-partial-size`, `aperture-partial-chunk`,
`aperture-excluded-files`, `aperture-excluded-buffers`. The names shadow consult's on
purpose.

### The child-frame layout (optional)

`(setq aperture-display 'child-frame)` floats the whole UI — prompt, candidate list and
preview pane — in a child frame, leaving any pre-existing windows visible behind it.

```
+-----------------------------------+
|  your windows untouched           |
|  +---------------+-------------+  |
|  | prompt+input  |             |  |
|  | candidates    |  preview    |  |
|  +---------------+-------------+  |
+-----------------------------------+
```

```elisp
(setq aperture-display 'child-frame
      aperture-child-frame-width 0.8        ; fraction of the parent, or columns
      aperture-child-frame-height 0.6       ; fraction of the parent, or lines
      aperture-child-frame-position 'center ; or 'top, or (X . Y), or a function
      aperture-child-frame-border-width 1
      aperture-child-frame-parameters nil)  ; frame parameters, applied last
```

Needs a graphical Emacs; on a TTY it falls back to the window layout and says so in the
log. `aperture-side`, `aperture-width` and `aperture-min-pane-width` work as usual — the
last widens the frame rather than taking over the parent. `aperture-height` and
`aperture-min-top-height` do not apply, since there is no top window.

**This is not `vertico-posframe` integration.** aperture creates and splits its own child
frame. If you use `vertico-posframe-mode`, aperture stands down for it per-session and
never touches the global mode, so your other minibuffers are unaffected — but your
`vertico-posframe-*` settings do not shape an aperture session. It also changes how consult
preview is targeted; [§3.4b](docs/DESIGN.md) has the mechanism and the tradeoff.

## Preview categories implemented

| Category                                        | Preview information                                                                       |
|-------------------------------------------------|-------------------------------------------------------------------------------------------|
| `symbol` `function` `variable` `command` `face` | signature, full docstring, current value                                                  |
| `file`                                          | file contents, fontified, bounded                                                         |
| `project-file`                                  | the same, resolved against the project root (`project-find-file`, `projectile-find-file`) |
| `buffer`                                        | the live buffer itself                                                                    |
| `package`                                       | version, dependencies, homepage, and the package's own `Commentary`                       |
| `bookmark`                                      | the target file, centred on the stored position                                           |
| `kill-ring`                                     | the entire entry                                                                          |

Anything else falls back to no pane at all, which is stock vertico.

Previewing is deliberately careful about what it will not do: it never calls `find-file`
(so no `find-file-hook`, no LSP client, no file-local variables on every keystroke), never
reads remote paths, never runs a bookmark handler, and never fetches a package README over
the network. Files over 1MB are read as a bounded head chunk rather than refused. When a
guard suppresses a preview, the pane says so and names the variable responsible.

## With consult

consult previews into `minibuffer-selected-window`, and aperture arranges for that window
*object* to be the pane, so consult's own preview lands there with no interception. For
categories consult drives itself (`consult-line`, `consult-ripgrep`, `consult-imenu`,
`consult-buffer`, xref, flymake, compile, org headings) aperture opens the pane for the
geometry and stands down. [§3.5](docs/DESIGN.md).

`aperture-consult.el` loads itself when consult is present and does nothing when it is not.
It exists for one defect: during a multi-file search, a hit in a buffer that is already
visible elsewhere would otherwise preview into that window and leave the pane stale.
[§3.5c](docs/DESIGN.md).

## Writing a previewer

A previewer is a function of one argument — the candidate string — returning `nil`, a
string, a plist, or (for async) a function taking a callback:

```elisp
(defun my-preview-emoji (cand)
  (list :content (format "%s\n\nU+%04X" cand (aref cand 0))
        :title " emoji"))

(put 'my-preview-emoji 'aperture-cost 'free)   ; skip the debounce entirely

(add-to-list 'aperture-previewer-registry '(emoji . my-preview-emoji))
```

Useful plist keys: `:content`, `:buffer` (display an existing buffer as-is; aperture never
kills a buffer it did not create), `:mode` or `:file` for fontification, `:goto`,
`:highlight`, `:title`, `:cancel`. Fontification, debouncing, error handling and discarding
stale results are the core's job, not yours. The full contract is
[§3.3](docs/DESIGN.md).

`aperture-command-previewers` maps a command symbol instead of a category, and wins over the
registry — the command is often more specific.

## Troubleshooting

```
M-x aperture-show-log
```

That turns logging on and shows the log; reproduce the problem and read it. It records every
point where aperture can silently do nothing: whether a session started and which reason it
declined for, where the windows actually landed, whether the candidate list
interception fired, when consult took over. Two failures look identical from the outside — a
session that never activated, and one that activated but laid its windows out wrong — and
the log is what separates them. Please include it in a bug report.

## Related packages

aperture is not a replacement for any of these and works alongside all of them.

- **marginalia** — one-line annotations. Complementary, and aperture is better with it
  installed.
- **consult** — search commands and their preview. aperture reshapes the windows those
  previews land in.
- **embark** — acting on a candidate, including `embark-collect` for a persistent buffer.
  That covers the "keep this open" case, which is why aperture always tears its pane down on
  exit.

## Non-goals

- A layout where the candidate list stays in the minibuffer and only the pane opens.
  Not supported: it is neither telescope nor stock vertico. [§3.4](docs/DESIGN.md).
- Driving `vertico-posframe`'s frame. The child-frame layout uses aperture's own.
  [§3.4b](docs/DESIGN.md).
- Replacing `describe-*` commands. The pane is for deciding *which* candidate; the real
  help buffer is for reading about it afterwards.

## Development

```bash
make deps            # install vertico, consult, package-lint into .deps/
make check           # compile, test, checkdoc, package-lint -- what CI runs
make try             # interactive smoke test in emacs -Q (TTY)
make try-child-frame # the same, with the child-frame layout (needs GUI Emacs)
make spike           # the child-frame layout spike, 29 hardware checks (GUI)
```

The child-frame layout has no CI coverage and cannot have any; `dev/spike-posframe.el` is
the executable record instead. [§3.4b](docs/DESIGN.md).

`make test` runs with no dependencies on the load path, on purpose: the core and the consult
adapter must both load without vertico or consult present. Point `DEPS` at your own checkouts
via an untracked `local.mk` if you prefer that to `make deps`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
