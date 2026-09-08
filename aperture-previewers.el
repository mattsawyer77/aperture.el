;;; aperture-previewers.el --- Built-in previewers for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; A previewer takes a candidate string and returns nil, a string, a plist, or
;; a function (async).  See docs/DESIGN.md section 3.3.
;;
;; Cost is declared with the `aperture-cost' symbol property: `free' bypasses
;; the debounce entirely, `expensive' lengthens it.

;;; Code:

(require 'aperture)
(require 'help-fns)

;; Required lazily so `aperture-mode' does not pull in package.el for a preview
;; that may never be asked for; compiled against here to stay warning-free.
(eval-when-compile
  (require 'package)
  (require 'bookmark)
  (require 'lisp-mnt)
  (require 'project))

;; `eval-when-compile' does not declare plain functions for run time.
(declare-function package--from-builtin "package" (bi))
(declare-function package-version-join "package" (vlist))
(declare-function package-desc-status "package" (pkg-desc))
(declare-function lm-commentary "lisp-mnt" (&optional file))
(declare-function bookmark-get-bookmark "bookmark" (bookmark-name-or-record &optional noerror))
(declare-function bookmark-get-bookmark-record "bookmark" (bookmark-name-or-record))
(declare-function bookmark-get-filename "bookmark" (bookmark-name-or-record))
(declare-function bookmark-get-position "bookmark" (bookmark-name-or-record))
(declare-function bookmark-get-handler "bookmark" (bookmark-name-or-record))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))
(declare-function projectile-project-root "projectile" (&optional dir))

;;;; Symbols

(defun aperture--symbol-signature (sym)
  "Return a signature line for SYM, or nil."
  (when (fboundp sym)
    (ignore-errors
      (let ((args (help-function-arglist sym t)))
        (format "(%s%s)" sym
                (if args (format " %s" (mapconcat #'symbol-name args " ")) ""))))))

(defun aperture-preview-symbol (cand)
  "Preview CAND as a symbol: signature, full docstring, and kind."
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

;;;; Project files

(defconst aperture--project-prompt-regexp
  "\\`\\(?:Dired\\|Find file\\) in \\(.*\\): \\'"
  "Matches a `project.el' prompt that names the root in its text.")

(defun aperture--project-root ()
  "Directory that `project-file' candidates are relative to, or nil.
Runs in the minibuffer, whose `default-directory' is inherited from
wherever completion was started and is unaffected by what the pane is
currently showing."
  (or
   ;; `project-find-file' names the root that produced the candidates in its
   ;; prompt, so it outranks any re-derivation.
   (and (minibufferp)
        (let ((prompt (or (minibuffer-prompt) ""))
              case-fold-search)
          (and (string-match aperture--project-prompt-regexp prompt)
               (match-string 1 prompt))))
   ;; projectile generated its candidates from its own notion of a root.
   (and (fboundp 'projectile-project-root)
        (ignore-errors (projectile-project-root)))
   (and (fboundp 'project-current)
        (when-let* ((proj (ignore-errors (project-current))))
          (ignore-errors (project-root proj))))))

(defun aperture-preview-project-file (cand)
  "Preview CAND, a `project-file' candidate, relative to the project root.
`project-file' candidates are relative to the project root, unlike `file'
candidates, which are relative to `default-directory'.  Absolute
candidates occur too: project directories carry this category as well."
  (require 'project nil t)
  (let ((name (substring-no-properties cand)))
    (if (file-name-absolute-p name)
        (aperture-preview-file name)
      (let ((default-directory (or (aperture--project-root) default-directory)))
        (aperture-preview-file name)))))

;;;; Buffers

(defun aperture-preview-buffer (cand)
  "Preview CAND as a live buffer.
Returns the buffer itself; aperture never kills a buffer it did not
create."
  (let ((name (substring-no-properties cand)))
    (cond
     ((aperture--excluded-p name aperture-excluded-buffers)
      "Preview suppressed: matches `aperture-excluded-buffers'")
     ((get-buffer name) (list :buffer (get-buffer name) :title (format " %s" name))))))

(put 'aperture-preview-buffer 'aperture-cost 'free)

;;;; Kill ring

(defun aperture-preview-kill-ring (cand)
  "Preview CAND as an entry from the `kill-ring'."
  (list :content (substring-no-properties cand)
        :title " kill-ring"))

(put 'aperture-preview-kill-ring 'aperture-cost 'free)

;;;; Packages

(defun aperture--package-desc (name)
  "Return a `package-desc' for the package symbol NAME, or nil.
Reads the three registries directly rather than calling
`package-get-descriptor', which runs `package-initialize' as a side
effect and still misses built-ins."
  (or (cadr (assq name package-alist))
      (cadr (assq name package-archive-contents))
      (when-let* ((builtin (assq name package--builtins)))
        (package--from-builtin builtin))))

(defun aperture--package-commentary (desc)
  "Return the Commentary section of DESC's main file, or nil.
Installed packages only: an uninstalled one has nothing on disk, and its
archive README would have to be fetched over the network, which a
previewer must never do."
  (when-let* ((dir (package-desc-dir desc))
              ;; `builtin' and `dir' are symbols, not paths.
              ((stringp dir))
              (file (expand-file-name
                     (format "%s.el" (package-desc-name desc)) dir))
              ((null (aperture-file-guard file)))
              (size (file-attribute-size (file-attributes file)))
              ((< size aperture-partial-size)))
    (ignore-errors (lm-commentary file))))

(defun aperture--package-reqs (desc)
  "Format DESC's dependencies as one line, or nil if it has none."
  (when-let* ((reqs (package-desc-reqs desc)))
    (mapconcat (lambda (req)
                 (format "%s %s" (car req) (package-version-join (cadr req))))
               reqs ", ")))

(defun aperture-preview-package (cand)
  "Preview CAND as a package: metadata, then its Commentary."
  (require 'package)
  (require 'lisp-mnt)
  (when-let* ((name (intern-soft (substring-no-properties cand)))
              (desc (aperture--package-desc name)))
    (let ((fields (delq nil
                        (list (cons "Version" (package-version-join
                                               (package-desc-version desc)))
                              (cons "Status" (ignore-errors
                                               (package-desc-status desc)))
                              (cons "Archive" (package-desc-archive desc))
                              (cons "Requires" (aperture--package-reqs desc))
                              (cons "Homepage" (alist-get
                                                :url (package-desc-extras desc))))))
          (summary (package-desc-summary desc)))
      (list :content
            (concat (format "%s  --  %s\n" name (or summary "no summary"))
                    (make-string (max 8 (length (symbol-name name))) ?=) "\n\n"
                    (mapconcat (lambda (f)
                                 (format "%-10s %s" (car f) (cdr f)))
                               (seq-filter #'cdr fields) "\n")
                    (if-let* ((commentary (aperture--package-commentary desc)))
                        (concat "\n\n" commentary)
                      ""))
            :title (format " %s" name)))))

;;;; Bookmarks

(defun aperture--bookmark-record (bmk)
  "Format the raw record of BMK for display."
  (mapconcat (lambda (cell)
               (format "%-22s %s" (car cell) (aperture--log-abbrev (cdr cell) 120)))
             (bookmark-get-bookmark-record bmk) "\n"))

(defun aperture--line-of-position (content pos)
  "Line number of character position POS within CONTENT."
  (with-temp-buffer
    (insert content)
    (goto-char (max (point-min) (min pos (point-max))))
    (line-number-at-pos)))

(defun aperture-preview-bookmark (cand)
  "Preview CAND as a bookmark: its target file, centred on the mark.
A bookmark carrying a handler can only be resolved by running that
handler, which visits the target for real; those show their stored record
instead."
  (require 'bookmark)
  (when-let* ((name (substring-no-properties cand))
              (bmk (bookmark-get-bookmark name 'noerror)))
    (let ((file (bookmark-get-filename bmk))
          (pos (or (bookmark-get-position bmk) 1))
          (title (format " %s" name)))
      (if (or (bookmark-get-handler bmk) (null file))
          (list :content (aperture--bookmark-record bmk) :title title)
        (let* ((file (expand-file-name file))
               (result (aperture-preview-file file)))
          (cond
           ;; A guard message; pass it through so it names its own variable.
           ((stringp result) result)
           ;; No `:file' means the file previewer produced a directory listing.
           ((null (plist-get result :file)) (plist-put result :title title))
           (t
            (let ((line (aperture--line-of-position
                         (plist-get result :content) pos)))
              (plist-put (plist-put result :goto line) :title
                         (format " %s  --  %s:%d" name
                                 (abbreviate-file-name file) line))))))))))

(provide 'aperture-previewers)
;;; aperture-previewers.el ends here
