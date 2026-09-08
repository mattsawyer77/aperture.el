;;; aperture-consult.el --- consult adapter for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; aperture needs almost nothing from consult: the pane *is*
;; `minibuffer-selected-window', so consult previews into it with no
;; interception.  Two adaptations remain.
;;
;; `consult--jump-ensure-buffer' prefers any window already showing the target
;; buffer over the selected one, and aperture manufactures such a window --
;; the top window is a split of the pane's, so both show the original buffer.
;; Jumping back to a hit in that buffer then previews into the top window and
;; leaves the pane stale.  Every position-preview command routes through this
;; function: grep, xref, compile, flymake, imenu-multi, register, org and
;; global-mark.
;;
;; `consult--original-window' names the pane for child-frame sessions, which
;; cannot rely on the `minibuffer-selected-window' invariant.
;;
;; This file is loaded only after consult is; with consult absent, nothing here
;; runs and nothing is advised.
;;
;; Design notes: docs/DESIGN.md sections 3.5 and 3.5c.

;;; Code:

(require 'aperture)

(declare-function consult--buffer-action "consult" (buffer &optional norecord))

(defun aperture-consult--pane-for-preview ()
  "Return the pane when consult is previewing into an aperture session.

Requires the pane to be the selected window, which is consult's own
signal that this is a preview: every `:state' call is wrapped in
`with-selected-window' on `consult--original-window'."
  (when-let* ((session (aperture--active-session))
              (pane (aperture--session-pane session))
              ((window-live-p pane))
              ((eq (selected-window) pane)))
    pane))

(defun aperture-consult--ensure-buffer (fn pos)
  "Around advice for `consult--jump-ensure-buffer', calling FN with POS.

Keeps preview in the pane instead of whichever window happens to already
show the target buffer, by forcing the branch consult already takes for
a file that is not currently visible.  Outside an aperture session this
calls through unchanged."
  (if-let* ((pane (aperture-consult--pane-for-preview))
            ((markerp pos))
            (buf (marker-buffer pos))
            ((buffer-live-p buf)))
      (progn
        (unless (eq (window-buffer pane) buf)
          (aperture--log "consult jump into pane: %s" (buffer-name buf))
          (consult--buffer-action buf 'norecord))
        t)
    (funcall fn pos)))

(defun aperture-consult--original-window (fn)
  "Around advice for `consult--original-window', calling FN.

Names the pane for child-frame sessions, which cannot rely on the pane
being `minibuffer-selected-window' the way the window layout does.

One function covers every preview path: `consult--jump-preview',
`consult--buffer-preview' and the rest all run inside
`with-selected-window (consult--original-window)' and then act on
`(selected-window)'.  Other sessions call through unchanged."
  (or (when-let* ((session (aperture--active-session))
                  ((aperture--session-frame session))
                  (pane (aperture--session-pane session))
                  ((window-live-p pane)))
        pane)
      (funcall fn)))

(defun aperture-consult-install ()
  "Install aperture's consult adaptations."
  (advice-add 'consult--jump-ensure-buffer :around #'aperture-consult--ensure-buffer)
  (advice-add 'consult--original-window :around #'aperture-consult--original-window))

(defun aperture-consult-uninstall ()
  "Remove aperture's consult adaptations."
  (advice-remove 'consult--jump-ensure-buffer #'aperture-consult--ensure-buffer)
  (advice-remove 'consult--original-window #'aperture-consult--original-window))

(provide 'aperture-consult)
;;; aperture-consult.el ends here
