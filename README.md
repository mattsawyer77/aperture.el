# aperture

[![CI](https://github.com/mattsawyer77/aperture.el/actions/workflows/ci.yml/badge.svg)](https://github.com/mattsawyer77/aperture.el/actions/workflows/ci.yml)

A preview pane for Emacs completion. Telescope-style two-pane UX, on vertico.

`marginalia` annotates each candidate with one line, because the completion API it
implements returns a string appended to the candidate. That ceiling is structural. aperture
adds a second surface — a pane rendering arbitrary, multi-line, fontified context for the
selected candidate — dispatched on the candidate's completion category, and working for any
`completing-read`.

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
its author. The design and its open questions are written down in
[docs/DESIGN.md](docs/DESIGN.md); if you are evaluating this, that file is more honest than
this one.

## Requirements

- Emacs 29.1+
- [vertico](https://github.com/minad/vertico), including `vertico-buffer` (same package)
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
         "aperture-consult.el"))
```

Recipes live in [melpa/melpa](https://github.com/melpa/melpa), not here.
</details>

## What it previews

| Category | Shows | Beats the one-line annotation by |
|---|---|---|
| `symbol` `function` `variable` `command` `face` | signature, full docstring, current value | the whole docstring instead of its truncated first line |
| `file` | file contents, fontified, bounded | showing the file rather than its size and mode |
| `project-file` | the same, resolved against the project root (`project-find-file`, `projectile-find-file`) | works from any buffer in the project, not only one at the root |
| `buffer` | the live buffer itself | same |
| `package` | version, dependencies, homepage, and the package's own `Commentary` | the summary line is rarely enough to decide whether to install |
| `bookmark` | the target file, centred on the stored position | a name with nothing behind it |
| `kill-ring` | the entire entry | multi-line kills are unreadable in one line |

Anything else falls back to no pane at all, which is stock vertico.

Previewing is deliberately careful about what it will not do: it never calls `find-file`
(so no `find-file-hook`, no LSP client, no file-local variables on every keystroke), never
reads remote paths, never runs a bookmark handler, and never fetches a package README over
the network. Files over 1MB are read as a bounded head chunk rather than refused. When a
guard suppresses a preview, the pane says so and names the variable responsible.

## With consult

consult previews into `minibuffer-selected-window`. aperture arranges for that window
*object* to be the pane, so consult's own preview lands there with no interception — see
[§3.5](docs/DESIGN.md). For categories consult drives itself (`consult-line`,
`consult-ripgrep`, `consult-imenu`, `consult-buffer`, xref, flymake, compile, org headings)
aperture opens the pane for the geometry and stands down.

One adapter is needed, `aperture-consult.el`, and it does exactly one thing: keep preview in
the pane when the target buffer is *already visible* in the window above it. Without it,
during a multi-file search, a hit back in your original buffer previews into the top window
and leaves the pane stale. [§3.5c](docs/DESIGN.md) documents the defect, the four cheaper
fixes that were tested and rejected, and why this one is safe. It loads itself when consult
is present and does nothing when it is not.

## Configuration

```elisp
(setq aperture-height 0.5       ; whole area: lines, or a fraction of the frame
      aperture-width 0.5        ; pane width within that area
      aperture-side 'right      ; or 'left
      aperture-key 'any         ; when to preview; grammar mirrors consult-preview-key
      aperture-delay 0.15)      ; debounce (ignored for cheap previewers)
```

`aperture-key` takes the same values as `consult-preview-key`, deliberately, so settings
transfer verbatim: `nil`, `any`, a key, a list of keys, or `(:debounce SECS any)`.

In the minibuffer, `C-M-v` and `C-M-S-v` scroll the pane without leaving the prompt.

Guards, all customizable: `aperture-partial-size`, `aperture-partial-chunk`,
`aperture-excluded-files`, `aperture-excluded-buffers`. The names shadow consult's on
purpose.

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

## Something is not working

```
M-x aperture-show-log
```

That turns logging on and shows the log; reproduce the problem and read it. It records every
point where aperture can silently do nothing: whether a session started and which reason it
declined for, where the three windows actually landed, whether the candidate list
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
- Replacing `describe-*` commands. The pane is for deciding *which* candidate; the real
  help buffer is for reading about it afterwards.

## Development

```bash
make deps     # install vertico, consult, package-lint into .deps/
make check    # compile, test, checkdoc, package-lint -- what CI runs
make try      # interactive smoke test in emacs -Q
```

`make test` runs with no dependencies on the load path, on purpose: the core and the consult
adapter must both load without vertico or consult present. Point `DEPS` at your own checkouts
via an untracked `local.mk` if you prefer that to `make deps`.

## License

GPL-3.0-or-later. See [LICENSE](LICENSE).
