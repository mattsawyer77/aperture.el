;;; aperture-vertico.el --- Vertico frontend for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Everything aperture knows about vertico lives here.  The core talks to it
;; only through `aperture-frontend', a plist of three functions.

;;; Code:

(require 'aperture)
(require 'vertico)
(require 'vertico-buffer)

(defvar vertico--input)
(defvar vertico--index)
(declare-function vertico--candidate "vertico")
(declare-function vertico-buffer-mode "vertico-buffer")
(declare-function vertico-posframe-mode-workable-p "vertico-posframe")

(defvar aperture-vertico--saved-buffer-mode 'unset
  "Value of `vertico-buffer-mode' before aperture enabled it.")

(defun aperture-vertico--active-p ()
  "Non-nil if vertico is active in the current minibuffer.

Tests `vertico--input', matching vertico's own `vertico--command-p'.
`vertico--index' must NOT be used: it is `defvar-local' with a non-nil
default of -1, so it reports true in every minibuffer."
  (bound-and-true-p vertico--input))

(defun aperture-vertico--candidate ()
  "Current vertico candidate, or nil."
  (ignore-errors (vertico--candidate)))

(defun aperture-vertico--index ()
  "Current vertico selection index."
  (bound-and-true-p vertico--index))

(defun aperture-vertico--setup (fn &rest args)
  "Build an aperture session, then run Vertico in the minibuffer buffer.

This must be one `:around' advice rather than independent `:before' and
`:around' advice.  Child-frame construction can switch `current-buffer';
restoring it here guarantees Vertico's primary method creates its local
overlays after Aperture has built the layout."
  (aperture--setup)
  (aperture--call-in-active-minibuffer
   (lambda ()
     (prog1 (apply fn args)
       (when-let* ((session aperture--session))
         (aperture--collapse-parent-minibuffer session))))))

(defun aperture-vertico--place-list (fn &rest args)
  "Around advice for `vertico-buffer--setup', calling FN with ARGS.

vertico-buffer picks its window by calling `display-buffer' on a
throwaway buffer.  `display-buffer-overriding-action' sits at the top of
`display-buffer''s precedence chain, so pointing it at the window we
already split wins regardless of the user's own display actions; a plain
`vertico-buffer-display-action' can be silently ignored."
  (if-let* ((session aperture--session)
            (win (aperture--session-list-win session))
            ((window-live-p win)))
      (let ((display-buffer-overriding-action
             (list (lambda (buffer _alist)
                     (set-window-buffer win buffer)
                     win))))
        (apply fn args)
        (aperture--log "list   placed in %s" (aperture--log-window win)))
    ;; Without a session this is stock vertico-buffer.
    (aperture--log "list   not placed: %s"
                   (if aperture--session "no live list window" "no session"))
    (apply fn args)))

(defun aperture-vertico--posframe-workable-p (fn &rest args)
  "Around advice for `vertico-posframe-mode-workable-p', calling FN with ARGS.
Report unworkable inside an aperture session, so vertico-posframe stands
down for those and only those.  Both packages hook
`vertico--display-candidates'; run together, the candidates overlay binds
to aperture's list window and the posframe shows a bare prompt.
Per-session is sufficient because `cl-defmethod' `&context' re-resolves
per call."
  (and (not (aperture--active-session)) (apply fn args)))

(defun aperture-vertico--suppress-posframe (enable)
  "Install or remove the vertico-posframe stand-down when ENABLE.
Polled at install time rather than hung off `with-eval-after-load', as
in `aperture--consult-arrange'."
  (when (fboundp 'vertico-posframe-mode-workable-p)
    (if enable
        (advice-add 'vertico-posframe-mode-workable-p :around
                    #'aperture-vertico--posframe-workable-p)
      (advice-remove 'vertico-posframe-mode-workable-p
                     #'aperture-vertico--posframe-workable-p))))

;;;###autoload
(defun aperture-vertico-install ()
  "Install the vertico frontend and list-window placement."
  (setq aperture-frontend
        (list :active-p #'aperture-vertico--active-p
              :candidate #'aperture-vertico--candidate
              :index #'aperture-vertico--index))
  ;; `vertico--setup' runs after `minibuffer-completion-table' is set and
  ;; before its own `:after' method calls `vertico-buffer--setup' -- the only
  ;; point satisfying both of `aperture--setup''s timing constraints.
  (advice-add 'vertico--setup :around #'aperture-vertico--setup)
  (advice-add 'vertico-buffer--setup :around #'aperture-vertico--place-list)
  (aperture-vertico--suppress-posframe t)
  ;; Both layouts put the candidate list in a window, which is
  ;; vertico-buffer's job; aperture does nothing without it.
  (when (eq aperture-vertico--saved-buffer-mode 'unset)
    (setq aperture-vertico--saved-buffer-mode (bound-and-true-p vertico-buffer-mode)))
  (vertico-buffer-mode 1))

(defun aperture-vertico-uninstall ()
  "Remove the vertico frontend and restore prior state."
  (setq aperture-frontend nil)
  (advice-remove 'vertico--setup #'aperture-vertico--setup)
  (advice-remove 'vertico-buffer--setup #'aperture-vertico--place-list)
  (aperture-vertico--suppress-posframe nil)
  (unless (eq aperture-vertico--saved-buffer-mode 'unset)
    (vertico-buffer-mode (if aperture-vertico--saved-buffer-mode 1 -1))
    (setq aperture-vertico--saved-buffer-mode 'unset)))

(provide 'aperture-vertico)
;;; aperture-vertico.el ends here
