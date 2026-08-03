;;; aperture-vertico.el --- Vertico frontend for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Everything aperture knows about vertico lives here.  The core talks to
;; `aperture-frontend', a plist of three functions, so it stays testable with a
;; stub and could grow another frontend later.

;;; Code:

(require 'aperture)
(require 'vertico)
(require 'vertico-buffer)

(defvar vertico--input)
(defvar vertico--index)
(declare-function vertico--candidate "vertico")
(declare-function vertico-buffer-mode "vertico-buffer")

(defvar aperture-vertico--saved-buffer-mode 'unset
  "Value of `vertico-buffer-mode' before aperture enabled it.")

(defun aperture-vertico--active-p ()
  "Non-nil if vertico is active in the current minibuffer.

Tests `vertico--input', matching vertico's own `vertico--command-p'.
`vertico--index' must NOT be used: it is `defvar-local' with a default
of -1, which is non-nil, so it reports true in every minibuffer --
including non-vertico ones such as `evil-ex'."
  (bound-and-true-p vertico--input))

(defun aperture-vertico--candidate ()
  "Current vertico candidate, or nil."
  (ignore-errors (vertico--candidate)))

(defun aperture-vertico--index ()
  "Current vertico selection index."
  (bound-and-true-p vertico--index))

(defun aperture-vertico--place-list (fn &rest args)
  "Around advice for `vertico-buffer--setup', calling FN with ARGS.

vertico-buffer picks its window by calling `display-buffer' on a
throwaway buffer.  A plain `vertico-buffer-display-action' is not
enough: it can be silently ignored in an opinionated configuration,
with no error and no diagnostic (docs/DESIGN.md section 3.5b).
`display-buffer-overriding-action' sits at the top of `display-buffer''s
precedence chain, so pointing it at the window we already split wins
regardless of what else the user's config is doing."
  (if-let* ((session aperture--session)
            (win (aperture--session-list-win session))
            ((window-live-p win)))
      (let ((display-buffer-overriding-action
             (list (lambda (buffer _alist)
                     (set-window-buffer win buffer)
                     win))))
        (apply fn args))
    (apply fn args)))

;;;###autoload
(defun aperture-vertico-install ()
  "Install the vertico frontend and list-window placement."
  (setq aperture-frontend
        (list :active-p #'aperture-vertico--active-p
              :candidate #'aperture-vertico--candidate
              :index #'aperture-vertico--index))
  ;; Session start hangs off `vertico--setup' rather than
  ;; `minibuffer-setup-hook'.  `completing-read-default' sets
  ;; `minibuffer-completion-table' from inside its own setup-hook lambda, so
  ;; any hook early enough to precede vertico-buffer is also too early to see
  ;; the completion table.  `vertico--setup' runs after the table is set and
  ;; before its own `:after' method calls `vertico-buffer--setup', which is
  ;; the only point satisfying both.
  (advice-add 'vertico--setup :before #'aperture--setup)
  (advice-add 'vertico-buffer--setup :around #'aperture-vertico--place-list)
  ;; aperture's only supported layout puts the candidate list in a window,
  ;; which is vertico-buffer's job.  Enable it rather than requiring the user
  ;; to discover that the package does nothing without it.
  (when (eq aperture-vertico--saved-buffer-mode 'unset)
    (setq aperture-vertico--saved-buffer-mode (bound-and-true-p vertico-buffer-mode)))
  (vertico-buffer-mode 1))

(defun aperture-vertico-uninstall ()
  "Remove the vertico frontend and restore prior state."
  (setq aperture-frontend nil)
  (advice-remove 'vertico--setup #'aperture--setup)
  (advice-remove 'vertico-buffer--setup #'aperture-vertico--place-list)
  (unless (eq aperture-vertico--saved-buffer-mode 'unset)
    (vertico-buffer-mode (if aperture-vertico--saved-buffer-mode 1 -1))
    (setq aperture-vertico--saved-buffer-mode 'unset)))

(provide 'aperture-vertico)
;;; aperture-vertico.el ends here
