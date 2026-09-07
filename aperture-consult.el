;;; aperture-consult.el --- consult adapter for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; aperture needs almost nothing from consult.  Because consult previews into
;; `minibuffer-selected-window', and because a window object survives being
;; split, aperture arranges for that window to *be* the pane and consult
;; previews into it with no interception at all (docs/DESIGN.md section 3.5).
;;
;; One thing does need fixing, and it is aperture's own fault.
;;
;; `consult--jump-ensure-buffer' prefers any window already showing the target
;; buffer over the selected one.  Aperture manufactures such a window: the top
;; window that keeps the original buffer visible is a split of the pane's
;; window, so both show the same buffer.  During a multi-file command:
;;
;;   hit in file F  ->  pane switches to F                          correct
;;   hit back in B  ->  consult finds B in the TOP window and previews there:
;;                      point moves, `consult-after-jump-hook' recenters it,
;;                      the match overlay is drawn there, and the pane is left
;;                      showing a stale F
;;
;; Every position-preview command routes through that function, so this covers
;; grep, xref, compile, flymake, imenu-multi, register, org and global-mark.
;; Window dedication and `no-other-window' do not help -- `get-buffer-window'
;; ignores both -- and `consult--buffer-display' is never reached on that
;; branch.  See section 3.5c for the alternatives that were tested and rejected.
;;
;; This file is loaded only after consult is; with consult absent, nothing here
;; runs and nothing is advised.

;;; Code:

(require 'aperture)

(declare-function consult--buffer-action "consult" (buffer &optional norecord))

(defun aperture-consult--pane-for-preview ()
  "Return the pane when consult is previewing into an aperture session.

Requires the pane to be the selected window, which is consult's own
signal that this is a preview: every `:state' call is wrapped in
`with-selected-window' on `consult--original-window'.  Anything else --
no session, a dead pane, some other window selected -- is none of our
business."
  (when-let* ((session (aperture--active-session))
              (pane (aperture--session-pane session))
              ((window-live-p pane))
              ((eq (selected-window) pane)))
    pane))

(defun aperture-consult--ensure-buffer (fn pos)
  "Around advice for `consult--jump-ensure-buffer', calling FN with POS.

Keeps preview in the pane instead of whichever window happens to already
show the target buffer.

Deliberately not a new code path: it forces the branch consult already
takes for any file that is not currently visible, so buffer lifecycle,
`norecord' handling and cleanup stay exactly as consult does them the
majority of the time.  Outside an aperture session this calls through
unchanged."
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
being `minibuffer-selected-window' the way the window layout does.  This
is the only place aperture redirects consult rather than reshaping around
it (docs/DESIGN.md section 3.4b).

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
