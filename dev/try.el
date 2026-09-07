;;; try.el --- Interactive smoke test for aperture -*- lexical-binding: t -*-

;; Launch with:  make try
;;
;; Runs aperture in a clean `emacs -Q', so nothing in a private config can
;; interfere.  Dependencies come from the Makefile's DEPS.  Try, in order:
;;
;;   M-x                 symbol previewer -- full docstrings, the flagship case
;;   C-x C-f             file previewer -- partial reads, fontified
;;   M-x consult-line    consult owns preview; aperture only owns the geometry
;;   M-x consult-ripgrep the §3.5c case, and the one batch cannot reach: search
;;                       for something matching in BOTH this buffer and another
;;                       file, then move between them.  Every hit must preview
;;                       in the pane.  If a hit in *try aperture* scrolls the
;;                       TOP window instead, the adapter is not doing its job.
;;   M-x describe-package  the §4.1 case.  These two commands declare no
;;   M-x bookmark-jump     completion category at all, so the pane depends
;;                         entirely on classification.  marginalia is NOT
;;                         loaded here, which is the point: this exercises
;;                         `aperture-prompt-categories', the path marginalia
;;                         users never reach.  No pane means the fallback is
;;                         broken; the log will say "no completion category".
;;                         (bookmark-jump needs a bookmark to exist first.)
;;
;; Expected layout:
;;
;;     +---------------------------------------+
;;     |  original buffer - stays visible      |
;;     +-------------------+-------------------+
;;     |  candidate list   |  preview pane     |
;;     +-------------------+-------------------+
;;     |  minibuffer                           |
;;     +---------------------------------------+
;;
;; `make try-child-frame' runs the same thing in a GUI Emacs with
;; `aperture-display' set to `child-frame'.  The layout floats instead, over
;; windows that must be exactly as you left them.  Check there that the frame
;; vanishes on both RET and C-g, and that the cursor is visible in the child
;; frame rather than stranded in the parent's minibuffer.

;;; Code:

(require 'vertico)
(require 'consult nil t)
(require 'aperture)

;; On, so that anything surprising is already recorded by the time you go
;; looking.  Set before `aperture-mode' so the mode's own marker line lands in
;; the log too.
(setq aperture-debug t)

;; Set before `aperture-mode' so the mode's marker line records which layout
;; the session was configured for.
(when (equal (getenv "APERTURE_DISPLAY") "child-frame")
  (setq aperture-display 'child-frame))

(vertico-mode 1)
(aperture-mode 1)

(with-current-buffer (get-buffer-create "*try aperture*")
  (insert "aperture smoke test\n===================\n\n")
  (insert (format "emacs    %s\n" emacs-version))
  (insert (format "aperture-key     %S\n" aperture-key))
  (insert (format "aperture-height  %S\n" aperture-height))
  (insert (format "aperture-display %S%s\n" aperture-display
                  (if (and (eq aperture-display 'child-frame)
                           (not (aperture--child-frame-capable-p)))
                      "  (degrades to `window': no graphic display)" "")))
  (insert (format "consult          %s\n\n" (if (featurep 'consult) "loaded" "absent")))
  (insert "Try:  M-x  /  C-x C-f  /  M-x consult-line\n\n")
  (insert "Checks:\n")
  (insert "  - original buffer still visible above the aperture area\n")
  (insert "  - candidate list left, preview pane right\n")
  (insert "  - M-x shows whole docstrings, updating instantly (cost `free')\n")
  (insert "  - consult-line previews into the SAME pane\n")
  (insert "  - consult-ripgrep: hits in THIS buffer preview in the pane,\n")
  (insert "    not in the window above it (see the header comment)\n")
  (insert "  - describe-package opens a pane at all -- no marginalia here,\n")
  (insert "    so this is testing the prompt-category fallback (§4.1)\n")
  (insert "  - exiting with RET or C-g restores this layout exactly\n\n")
  (insert "Logging is on: M-x aperture-show-log to see what actually happened.\n")
  (goto-char (point-min)))
(switch-to-buffer "*try aperture*")

;;; try.el ends here
