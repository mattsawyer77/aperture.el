;;; aperture-previewers.el --- Built-in previewers for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A previewer takes a candidate string and returns nil, a string, a plist, or
;; a function (async).  See docs/DESIGN.md section 3.3.
;;
;; Cost is declared with the `aperture-cost' symbol property.  It exists for
;; the fast path: `free' bypasses the debounce entirely, which is the
;; difference between `M-x' feeling instant and merely feeling fast.

;;; Code:

(require 'aperture)
(require 'help-fns)

;;;; Symbols -- the flagship

(defun aperture--symbol-signature (sym)
  "Return a signature line for SYM, or nil."
  (when (fboundp sym)
    (ignore-errors
      (let ((args (help-function-arglist sym t)))
        (format "(%s%s)" sym
                (if args (format " %s" (mapconcat #'symbol-name args " ")) ""))))))

(defun aperture-preview-symbol (cand)
  "Preview CAND as a symbol: signature, full docstring, and kind.

This is the case with no existing answer in the ecosystem.  marginalia
can show a truncated first line; the whole point of the pane is that the
rest of the docstring has somewhere to go."
  (when-let* ((sym (intern-soft (substring-no-properties cand))))
    (let* ((parts nil)
           (kind (cond ((commandp sym) "command")
                       ((functionp sym) "function")
                       ((custom-variable-p sym) "user option")
                       ((boundp sym) "variable")
                       ((facep sym) "face")
                       (t "symbol"))))
      (push (format "%s  --  %s" sym kind) parts)
      (push (make-string (max 8 (length (symbol-name sym))) ?=) parts)
      (when-let* ((sig (aperture--symbol-signature sym)))
        (push (concat "\n" sig) parts))
      (when (fboundp sym)
        (push (concat "\n" (or (ignore-errors (documentation sym))
                               "Not documented."))
              parts))
      (when (boundp sym)
        (push (format "\n%sValue: %S\n\n%s"
                      (if (fboundp sym) "\n" "") (symbol-value sym)
                      (or (documentation-property sym 'variable-documentation)
                          "Not documented."))
              parts))
      (list :content (string-join (nreverse parts) "\n")
            :title (format " %s" sym)))))

(put 'aperture-preview-symbol 'aperture-cost 'free)

;;;; Files

(defun aperture-preview-file (cand)
  "Preview CAND as a file, relative to the minibuffer's directory."
  (let ((file (expand-file-name (substring-no-properties cand))))
    (cond
     ((aperture-file-guard file))
     ((file-directory-p file)
      (list :content (string-join (directory-files file) "\n")
            :title (format " %s" (abbreviate-file-name file))))
     (t
      (let (truncated)
        (list :content (with-temp-buffer
                         (setq truncated (aperture-insert-file file))
                         (when truncated
                           (goto-char (point-max))
                           (insert "\n\n[truncated: see `aperture-partial-size']"))
                         (buffer-string))
              :file file
              :title (format " %s" (abbreviate-file-name file))))))))

;;;; Buffers

(defun aperture-preview-buffer (cand)
  "Preview CAND as a live buffer.
Returns the buffer itself: aperture displays it as-is and never kills a
buffer it did not create."
  (let ((name (substring-no-properties cand)))
    (cond
     ((aperture--excluded-p name aperture-excluded-buffers)
      "Preview suppressed: matches `aperture-excluded-buffers'")
     ((get-buffer name) (list :buffer (get-buffer name) :title (format " %s" name))))))

(put 'aperture-preview-buffer 'aperture-cost 'free)

;;;; Kill ring

(defun aperture-preview-kill-ring (cand)
  "Preview CAND as a kill-ring entry.
Multi-line kills are unreadable in a one-line annotation."
  (list :content (substring-no-properties cand)
        :title " kill-ring"))

(put 'aperture-preview-kill-ring 'aperture-cost 'free)

(provide 'aperture-previewers)
;;; aperture-previewers.el ends here
