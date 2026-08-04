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

;; `package' and `bookmark' are built-in, but each is only reachable once the
;; user is already completing its own candidates -- by which point the library
;; is necessarily loaded.  Requiring them lazily keeps `aperture-mode' from
;; pulling in package.el for a preview that may never be asked for; compiling
;; against them keeps that free of warnings.
(eval-when-compile
  (require 'package)
  (require 'bookmark)
  (require 'lisp-mnt)
  (require 'project))

;; `eval-when-compile' inlines the struct accessors and declares the registry
;; variables, but the compiler still cannot see plain functions at run time.
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

;;;; Project files

(defconst aperture--project-prompt-regexp
  "\\`\\(?:Dired\\|Find file\\) in \\(.*\\): \\'"
  "Matches a `project.el' prompt that names the root in its text.")

(defun aperture--project-root ()
  "Directory that `project-file' candidates are relative to, or nil.

Runs in the minibuffer, whose `default-directory' is inherited from
wherever completion was started -- stable for the whole session, and
unaffected by what the pane is currently showing."
  (or
   ;; `project-find-file' names the root in its prompt.  That is the root
   ;; which produced the candidates, so it outranks any re-derivation.
   (and (minibufferp)
        (let ((prompt (or (minibuffer-prompt) ""))
              case-fold-search)
          (and (string-match aperture--project-prompt-regexp prompt)
               (match-string 1 prompt))))
   ;; projectile has its own notion of a root, and its own candidates were
   ;; generated from it; when projectile is asking, its answer is the one.
   (and (fboundp 'projectile-project-root)
        (ignore-errors (projectile-project-root)))
   (and (fboundp 'project-current)
        (when-let* ((proj (ignore-errors (project-current))))
          (ignore-errors (project-root proj))))))

(defun aperture-preview-project-file (cand)
  "Preview CAND, a `project-file' candidate, relative to the project root.

`project-file' candidates are relative to the project root; `file'
candidates are relative to `default-directory'.  The two coincide exactly
when completion was started from a buffer sitting at the root, which is
why using the file previewer for both looks correct in a flat repository
and fails in every nested one.  Absolute candidates occur too -- project
directories are reported under this category as well."
  (require 'project nil t)
  (let ((name (substring-no-properties cand)))
    (if (file-name-absolute-p name)
        (aperture-preview-file name)
      (let ((default-directory (or (aperture--project-root) default-directory)))
        (aperture-preview-file name)))))

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
  "Preview CAND as an entry from the `kill-ring'.
Multi-line kills are unreadable in a one-line annotation."
  (list :content (substring-no-properties cand)
        :title " kill-ring"))

(put 'aperture-preview-kill-ring 'aperture-cost 'free)

;;;; Packages

(defun aperture--package-desc (name)
  "Return a `package-desc' for the package symbol NAME, or nil.

Reads the three registries directly rather than calling
`package-get-descriptor', which runs `package-initialize' as a side
effect -- unacceptable on a keystroke -- and still misses built-ins,
which are much of what `describe-package' is pointed at."
  (or (cadr (assq name package-alist))
      (cadr (assq name package-archive-contents))
      (when-let* ((builtin (assq name package--builtins)))
        (package--from-builtin builtin))))

(defun aperture--package-commentary (desc)
  "Return the Commentary section of DESC's main file, or nil.

Installed packages only.  An uninstalled one has nothing on disk, and its
long description lives in an archive README that `describe-package' will
fetch over the network -- which is precisely what a previewer running on
every selection change must never do."
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
  "Preview CAND as a package: metadata, then its Commentary.

The Commentary is the part worth a pane.  `describe-package' shows it in
full, marginalia shows the one-line summary; between those two there is
nothing, and the summary is rarely enough to decide whether to install."
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

A bookmark carrying a handler belongs to whichever package created it,
and the only way to resolve it is to run that handler -- which visits the
target for real.  Those show their stored record instead, which still
beats a name with nothing behind it."
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
