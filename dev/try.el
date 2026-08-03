;;; try.el --- Interactive smoke test for aperture -*- lexical-binding: t -*-

;; Launch with:  make try
;;
;; Runs aperture in a clean `emacs -Q', so nothing in a private config can
;; interfere.  Dependencies come from the Makefile's DEPS.  Try, in order:
;;
;;   M-x                 symbol previewer -- full docstrings, the flagship case
;;   C-x C-f             file previewer -- partial reads, fontified
;;   M-x consult-line    consult owns preview; aperture only owns the geometry
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

;;; Code:

(require 'vertico)
(require 'consult nil t)
(require 'aperture)

(vertico-mode 1)
(aperture-mode 1)

(with-current-buffer (get-buffer-create "*try aperture*")
  (insert "aperture smoke test\n===================\n\n")
  (insert (format "emacs    %s\n" emacs-version))
  (insert (format "aperture-key     %S\n" aperture-key))
  (insert (format "aperture-height  %S\n" aperture-height))
  (insert (format "consult          %s\n\n" (if (featurep 'consult) "loaded" "absent")))
  (insert "Try:  M-x  /  C-x C-f  /  M-x consult-line\n\n")
  (insert "Checks:\n")
  (insert "  - original buffer still visible above the aperture area\n")
  (insert "  - candidate list left, preview pane right\n")
  (insert "  - M-x shows whole docstrings, updating instantly (cost `free')\n")
  (insert "  - consult-line previews into the SAME pane\n")
  (insert "  - exiting with RET or C-g restores this layout exactly\n")
  (goto-char (point-min)))
(switch-to-buffer "*try aperture*")

;;; try.el ends here
