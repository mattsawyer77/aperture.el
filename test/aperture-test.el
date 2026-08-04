;;; aperture-test.el --- Tests for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The interactive layer is hard to test in batch, so the design pushes logic
;; out of it specifically so it can be tested here: result normalization,
;; registry resolution order, the preview-key grammar, cost/debounce, the
;; guards, and the activation decision.  Layout and frontend behaviour need a
;; real frame; use `make try', with `aperture-debug' on.

;;; Code:

(require 'ert)
(require 'aperture)
(require 'aperture-previewers)
;; Loads without consult, on purpose: the adapter is soft-dependent, and being
;; able to load it here is what lets its logic be tested at all.
(require 'aperture-consult)

;;;; Normalization

(ert-deftest aperture-test-normalize-nil ()
  (should (null (aperture--normalize nil))))

(ert-deftest aperture-test-normalize-string ()
  (should (equal (aperture--normalize "hi") '(:content "hi"))))

(ert-deftest aperture-test-normalize-plist ()
  (let ((p '(:content "x" :mode text-mode)))
    (should (eq (aperture--normalize p) p))))

(ert-deftest aperture-test-normalize-function ()
  (let ((r (aperture--normalize #'ignore)))
    (should (eq (plist-get r :async) #'ignore))))

(ert-deftest aperture-test-normalize-lambda-is-async-not-plist ()
  "A lambda is a cons; it must not be mistaken for a plist."
  (let ((r (aperture--normalize (lambda (_cb) nil))))
    (should (functionp (plist-get r :async)))))

(ert-deftest aperture-test-normalize-rejects-garbage ()
  (should-error (aperture--normalize 42)))

;;;; Registry resolution

(ert-deftest aperture-test-registry-by-category ()
  (let ((aperture-previewer-registry '((file . my-file-previewer)))
        (aperture-command-previewers nil))
    (should (eq (aperture--previewer-for 'file 'find-file) 'my-file-previewer))
    (should (null (aperture--previewer-for 'buffer 'find-file)))))

(ert-deftest aperture-test-command-beats-category ()
  "The command is often more specific than the category."
  (let ((aperture-previewer-registry '((file . by-category)))
        (aperture-command-previewers '((find-file . by-command))))
    (should (eq (aperture--previewer-for 'file 'find-file) 'by-command))
    (should (eq (aperture--previewer-for 'file 'other-cmd) 'by-category))))

;;;; Preview key grammar

(ert-deftest aperture-test-key-nil ()
  (should (equal (aperture--key-normalize nil) '(nil . 0))))

(ert-deftest aperture-test-key-any ()
  (let ((aperture-delay 0.15))
    (should (equal (aperture--key-normalize 'any) '(t . 0.15)))))

(ert-deftest aperture-test-key-debounce ()
  (should (equal (aperture--key-normalize '(:debounce 0.4 any)) '(t . 0.4))))

(ert-deftest aperture-test-key-single ()
  (should (equal (aperture--key-normalize "M-.") '(("M-.") . 0))))

(ert-deftest aperture-test-live-p ()
  (should (let ((aperture-key 'any)) (aperture--live-p)))
  (should-not (let ((aperture-key nil)) (aperture--live-p)))
  (should-not (let ((aperture-key "M-.")) (aperture--live-p))))

;;;; Cost and debounce

(ert-deftest aperture-test-cost-default-is-cheap ()
  (should (eq (aperture--cost #'ignore) 'cheap)))

(ert-deftest aperture-test-free-cost-bypasses-debounce ()
  "`:cost free' exists for the fast path: no debounce at all."
  (let ((aperture-key 'any) (aperture-delay 0.15))
    (should (= (aperture--delay-for #'aperture-preview-symbol) 0))
    (should (= (aperture--delay-for #'ignore) 0.15))))

(ert-deftest aperture-test-expensive-cost-lengthens-debounce ()
  (let ((aperture-key 'any) (aperture-delay 0.1))
    (put 'aperture-test--slow 'aperture-cost 'expensive)
    (should (> (aperture--delay-for 'aperture-test--slow) 0.1))))

;;;; Guards

(ert-deftest aperture-test-excluded-p ()
  (should (aperture--excluded-p "x.gpg" '("\\.gpg\\'")))
  (should-not (aperture--excluded-p "x.el" '("\\.gpg\\'"))))

(ert-deftest aperture-test-file-guard-excludes-remote ()
  "A synchronous TRAMP read is the failure debouncing cannot rescue."
  (should (stringp (aperture-file-guard "/ssh:host:/etc/passwd"))))

(ert-deftest aperture-test-file-guard-excludes-by-regexp ()
  (let ((aperture-excluded-files '("\\.gpg\\'")))
    (should (stringp (aperture-file-guard "/tmp/secret.gpg")))))

(ert-deftest aperture-test-file-guard-allows-normal-file ()
  (let ((file (make-temp-file "aperture-test")))
    (unwind-protect
        (let ((aperture-excluded-files nil))
          (should (null (aperture-file-guard file))))
      (delete-file file))))

(ert-deftest aperture-test-partial-read-truncates ()
  "Large files are previewed partially, not refused."
  (let ((file (make-temp-file "aperture-test")))
    (unwind-protect
        (progn
          (with-temp-file file (insert (make-string 5000 ?x)))
          (let ((aperture-partial-size 100)
                (aperture-partial-chunk 50))
            (with-temp-buffer
              (should (aperture-insert-file file))
              (should (= (buffer-size) 50)))))
      (delete-file file))))

(ert-deftest aperture-test-small-file-read-whole ()
  (let ((file (make-temp-file "aperture-test")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "hello"))
          (let ((aperture-partial-size 1000))
            (with-temp-buffer
              (should-not (aperture-insert-file file))
              (should (equal (buffer-string) "hello")))))
      (delete-file file))))

;;;; Staleness

(ert-deftest aperture-test-generation-staleness ()
  "A callback from a superseded request must be discarded."
  (let ((s (aperture--session-make :generation 5)))
    (should (aperture--fresh-p s 5))
    (should-not (aperture--fresh-p s 4))))

;;;; Previewers

(ert-deftest aperture-test-symbol-previewer-includes-full-docstring ()
  (let ((r (aperture-preview-symbol "car")))
    (should (string-match-p "car" (plist-get r :content)))
    ;; The whole point: more than one line of documentation.
    (should (> (length (split-string (plist-get r :content) "\n")) 3))))

(ert-deftest aperture-test-symbol-previewer-unknown-symbol ()
  (should (null (aperture-preview-symbol "no-such-symbol-xyzzy-42"))))

(ert-deftest aperture-test-buffer-previewer-returns-buffer ()
  (let ((buf (generate-new-buffer "aperture-test-buf")))
    (unwind-protect
        (should (eq (plist-get (aperture-preview-buffer (buffer-name buf)) :buffer) buf))
      (kill-buffer buf))))

(ert-deftest aperture-test-buffer-previewer-respects-exclusions ()
  (let ((aperture-excluded-buffers '("\\` ")))
    (should (stringp (aperture-preview-buffer " *hidden*")))))

;;;; Project-file previewer

(defmacro aperture-test--with-project (&rest body)
  "Run BODY with `root' bound to a project root holding sub/deep.txt.
`aperture--project-root' is stubbed: resolving a real root needs a VCS or
projectile, neither of which this suite may depend on."
  (declare (indent 0) (debug t))
  `(let* ((root (file-name-as-directory (make-temp-file "aperture-proj" t)))
          (sub (expand-file-name "sub/" root)))
     (unwind-protect
         (progn
           (make-directory sub)
           (with-temp-file (expand-file-name "sub/deep.txt" root)
             (insert "found it"))
           (cl-letf (((symbol-function 'aperture--project-root) (lambda () root)))
             ,@body))
       (delete-directory root t))))

(ert-deftest aperture-test-project-file-resolves-against-the-root ()
  "Candidates are relative to the project root, not `default-directory'.
The two coincide only when completion was started from a buffer at the
root, which is why this looks fine in a flat repository and fails in
every nested one."
  (aperture-test--with-project
    (let* ((default-directory sub)     ; started from a subdirectory
           (r (aperture-preview-project-file "sub/deep.txt")))
      (should-not (stringp r))         ; a string here is a guard message
      (should (equal (plist-get r :content) "found it")))))

(ert-deftest aperture-test-project-file-still-works-from-the-root ()
  "The case that always worked must keep working."
  (aperture-test--with-project
    (let* ((default-directory root)
           (r (aperture-preview-project-file "sub/deep.txt")))
      (should (equal (plist-get r :content) "found it")))))

(ert-deftest aperture-test-project-file-accepts-absolute-candidates ()
  "Project directories are reported under this category too, absolute."
  (aperture-test--with-project
    (let* ((default-directory "/")
           (r (aperture-preview-project-file
               (expand-file-name "sub/deep.txt" root))))
      (should (equal (plist-get r :content) "found it")))))

(ert-deftest aperture-test-project-root-falls-back-to-default-directory ()
  "With no root resolvable, behave exactly as the file previewer does."
  (let ((file (make-temp-file "aperture-proj-flat")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "flat"))
          (cl-letf (((symbol-function 'aperture--project-root) #'ignore))
            (let* ((default-directory (file-name-directory file))
                   (r (aperture-preview-project-file
                       (file-name-nondirectory file))))
              (should (equal (plist-get r :content) "flat")))))
      (delete-file file))))

(ert-deftest aperture-test-project-prompt-regexp-matches-project-find-file ()
  "`project-find-file' names the root in its prompt; that beats guessing."
  (should (string-match aperture--project-prompt-regexp
                        "Find file in ~/src/thing/: "))
  (should (equal (match-string 1 "Find file in ~/src/thing/: ") "~/src/thing/"))
  (should (string-match aperture--project-prompt-regexp "Dired in /tmp/x/: "))
  ;; projectile prepends the project name, so it must NOT match here -- its
  ;; own root is consulted instead.
  (should-not (string-match aperture--project-prompt-regexp
                            "[my-project] Find file: ")))

;;;; Package previewer

(ert-deftest aperture-test-package-previewer-finds-a-builtin ()
  "Built-ins must resolve; `package-get-descriptor' does not return them."
  (require 'package)
  (require 'finder-inf nil t)
  (skip-unless package--builtins)
  (let ((r (aperture-preview-package "seq")))
    (should (string-match-p "^seq " (plist-get r :content)))
    (should (string-match-p "Version" (plist-get r :content)))))

(ert-deftest aperture-test-package-previewer-unknown-package ()
  (should (null (aperture-preview-package "no-such-package-xyzzy-42"))))

(ert-deftest aperture-test-package-previewer-includes-commentary ()
  "The Commentary is the part that earns a pane; the summary is marginalia's."
  (require 'package)
  (let* ((dir (make-temp-file "aperture-pkg" t))
         (file (expand-file-name "faux.el" dir)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert ";;; faux.el --- x -*- lexical-binding: t -*-\n"
                    ";;; Commentary:\n;; A distinctive sentence.\n;;; Code:\n"
                    "(provide 'faux)\n"))
          (let* ((desc (package-desc-create :name 'faux :version '(1 0)
                                            :summary "s" :dir dir :kind 'single))
                 (package-alist (list (list 'faux desc)))
                 (r (aperture-preview-package "faux")))
            (should (string-match-p "A distinctive sentence"
                                    (plist-get r :content)))))
      (delete-directory dir t))))

(ert-deftest aperture-test-package-commentary-skipped-when-not-installed ()
  "An uninstalled package's description is a network fetch away.
A previewer running on every keystroke may not go and get it."
  (require 'package)
  (should (null (aperture--package-commentary
                 (package-desc-create :name 'faux :version '(1 0)
                                      :summary "s" :kind 'single)))))

;;;; Bookmark previewer

(defmacro aperture-test--with-bookmarks (&rest body)
  "Run BODY with `bookmark-alist' bound to a fixture and `file' to its target."
  (declare (indent 0) (debug t))
  `(let ((file (make-temp-file "aperture-bmk" nil ".el"
                               "(line 1)\n(line 2)\n(line 3)\n(line 4)\n")))
     (unwind-protect
         (let ((bookmark-alist
                `(("to-line-3" (filename . ,file) (position . 19))
                  ("handled" (filename . ,file) (position . 1)
                   (handler . bookmark-jump-noop))
                  ("no-file" (position . 1) (front-context-string . "x")))))
           ,@body)
       (delete-file file))))

(ert-deftest aperture-test-bookmark-previewer-goes-to-the-line ()
  "A bookmark stores a character position; `:goto' is a line number."
  (require 'bookmark)
  (aperture-test--with-bookmarks
    (let ((r (aperture-preview-bookmark "to-line-3")))
      (should (= (plist-get r :goto) 3))
      (should (equal (plist-get r :file) file))
      (should (string-match-p ":3\\'" (plist-get r :title))))))

(ert-deftest aperture-test-bookmark-previewer-does-not-run-handlers ()
  "Resolving a handled bookmark means visiting its target for real."
  (require 'bookmark)
  (aperture-test--with-bookmarks
    (let ((r (aperture-preview-bookmark "handled")))
      (should (null (plist-get r :file)))
      (should (string-match-p "handler" (plist-get r :content))))))

(ert-deftest aperture-test-bookmark-previewer-without-a-file ()
  (require 'bookmark)
  (aperture-test--with-bookmarks
    (should (string-match-p "front-context-string"
                            (plist-get (aperture-preview-bookmark "no-file")
                                       :content)))))

(ert-deftest aperture-test-bookmark-previewer-unknown-bookmark ()
  (require 'bookmark)
  (aperture-test--with-bookmarks
    (should (null (aperture-preview-bookmark "no-such-bookmark")))))

(ert-deftest aperture-test-line-of-position-clamps ()
  (should (= (aperture--line-of-position "a\nb\nc" 1) 1))
  (should (= (aperture--line-of-position "a\nb\nc" 5) 3))
  (should (= (aperture--line-of-position "a\nb\nc" 9999) 3)))

;;;; Category classification

(ert-deftest aperture-test-prompt-classifier ()
  "`describe-package' and friends declare no category at all.
Without this fallback the two previewers above can never fire."
  (should (eq (aperture--classify-prompt "Describe package (default seq): ")
              'package))
  (should (eq (aperture--classify-prompt "Install package: ") 'package))
  (should (eq (aperture--classify-prompt "Jump to bookmark (default x): ")
              'bookmark))
  (should (null (aperture--classify-prompt "M-x ")))
  (should (null (aperture--classify-prompt ""))))

(ert-deftest aperture-test-consult-owned-categories-open-a-pane ()
  "Each must still open a pane, having no previewer of aperture's own.
Without a session there is no pane for consult to preview into."
  (let ((aperture-key 'any)
        (aperture-frontend '(:active-p ignore)))
    (dolist (cat '(consult-location consult-grep imenu multi-category
                                    org-heading consult-flymake-error))
      (should (null (aperture--skip-reason cat 'some-consult-command))))))

;;;; Activation decision

(ert-deftest aperture-test-skip-reason-names-the-cause ()
  "Each way of doing nothing must be distinguishable in the log."
  (let ((aperture-frontend '(:active-p ignore))
        (aperture-previewer-registry '((file . aperture-preview-file)))
        (aperture-command-previewers nil)
        (aperture-consult-categories '(consult-location)))
    (should (string-match-p "aperture-key"
                            (let ((aperture-key nil))
                              (aperture--skip-reason 'file 'find-file))))
    (should (string-match-p "frontend"
                            (let ((aperture-key 'any) (aperture-frontend nil))
                              (aperture--skip-reason 'file 'find-file))))
    (let ((aperture-key 'any))
      (should (string-match-p "no completion category"
                              (aperture--skip-reason nil 'some-command)))
      (should (string-match-p "buffer" (aperture--skip-reason 'buffer 'x)))
      ;; A consult-owned category activates for the geometry alone, with no
      ;; previewer of our own.
      (should (null (aperture--skip-reason 'consult-location 'consult-line)))
      (should (null (aperture--skip-reason 'file 'find-file))))))

;;;; consult adapter

;; The window arrangement that provokes the bug needs a live minibuffer and a
;; real frame, so it is reproduced by hand in §3.5c rather than here.  What is
;; testable is the decision: when to divert preview into the pane, when to
;; leave consult alone, and that "already showing" is not a redundant switch.

(defmacro aperture-test--with-consult-stub (pane &rest body)
  "Run BODY with PANE as the preview target and consult stubbed out.
Binds `calls' to a list of what the advice did."
  (declare (indent 1) (debug t))
  `(let (calls)
     (cl-letf (((symbol-function 'aperture-consult--pane-for-preview)
                (lambda () ,pane))
               ((symbol-function 'consult--buffer-action)
                (lambda (buf &optional _norecord) (push (cons 'action buf) calls))))
       ,@body
       (nreverse calls))))

(ert-deftest aperture-test-consult-diverts-preview-into-the-pane ()
  "The whole point: a target visible elsewhere still previews in the pane."
  (let* ((buf (generate-new-buffer "aperture-test-target"))
         (other (generate-new-buffer "aperture-test-other"))
         (win (selected-window)))
    (unwind-protect
        (let ((pos (with-current-buffer buf (insert "hi") (copy-marker 1))))
          (set-window-buffer win other)
          (let* ((fn-called nil)
                 (calls (aperture-test--with-consult-stub win
                          (should (eq t (aperture-consult--ensure-buffer
                                         (lambda (_pos) (setq fn-called t) 'stock)
                                         pos))))))
            ;; consult's own resolution must not run, and ours must.
            (should-not fn-called)
            (should (equal calls (list (cons 'action buf))))))
      (kill-buffer buf)
      (kill-buffer other))))

(ert-deftest aperture-test-consult-does-not-reswitch-visible-buffer ()
  "If the pane already shows the target there is nothing to do."
  (let ((buf (generate-new-buffer "aperture-test-target"))
        (win (selected-window)))
    (unwind-protect
        (let ((pos (with-current-buffer buf (insert "hi") (copy-marker 1))))
          (set-window-buffer win buf)
          (should (null (aperture-test--with-consult-stub win
                          (should (eq t (aperture-consult--ensure-buffer
                                         #'ignore pos)))))))
      (kill-buffer buf))))

(ert-deftest aperture-test-consult-passes-through-without-a-session ()
  "With no aperture session, consult must behave exactly as it does alone."
  (let ((buf (generate-new-buffer "aperture-test-target")))
    (unwind-protect
        (let ((pos (with-current-buffer buf (insert "hi") (copy-marker 1))))
          (should (null (aperture-test--with-consult-stub nil
                          (should (eq 'stock (aperture-consult--ensure-buffer
                                              (lambda (_pos) 'stock) pos)))))))
      (kill-buffer buf))))

(ert-deftest aperture-test-consult-passes-through-non-markers ()
  "A plain position carries no buffer; consult's own handling applies."
  (should (null (aperture-test--with-consult-stub (selected-window)
                  (should (eq 'stock (aperture-consult--ensure-buffer
                                      (lambda (_pos) 'stock) 42)))))))

(ert-deftest aperture-test-consult-passes-through-dead-buffer ()
  "A marker into a killed buffer must not be diverted."
  (let* ((buf (generate-new-buffer "aperture-test-target"))
         (pos (with-current-buffer buf (insert "hi") (copy-marker 1))))
    (kill-buffer buf)
    (should (null (aperture-test--with-consult-stub (selected-window)
                    (should (eq 'stock (aperture-consult--ensure-buffer
                                        (lambda (_pos) 'stock) pos))))))))

(ert-deftest aperture-test-active-session-is-nil-without-a-minibuffer ()
  (should (null (aperture--active-session))))

(ert-deftest aperture-test-consult-adapter-not-installed-without-consult ()
  "Invariant 5: nothing about consult may be touched when it is absent.
This suite runs with no consult on the load path, which is the point."
  (skip-unless (not (featurep 'consult)))
  (let (installed)
    (cl-letf (((symbol-function 'aperture-consult-install)
               (lambda () (setq installed t))))
      (aperture--consult-arrange)
      (should-not installed))))

(ert-deftest aperture-test-consult-adapter-installs-when-consult-appears ()
  "consult may be loaded long after `aperture-mode'.
Polling at session setup is what notices; a `with-eval-after-load' hook
would survive the mode being turned off."
  (let ((installed 0))
    (unwind-protect
        (cl-letf (((symbol-function 'aperture-consult-install)
                   (lambda () (setq installed (1+ installed)))))
          ;; The real thing: `features' is not a special variable, so
          ;; let-binding it under lexical binding is invisible to `featurep'.
          (provide 'consult)
          (aperture--consult-arrange)
          (aperture--consult-arrange)
          ;; Called every session; `advice-add' makes the repeat harmless.
          (should (= installed 2)))
      (setq features (delq 'consult features)))))

;;;; Logging

(ert-deftest aperture-test-log-is-inert-when-disabled ()
  "Logging must cost nothing, and create nothing, when off."
  (when-let* ((buf (get-buffer aperture-log-buffer))) (kill-buffer buf))
  (let ((aperture-debug nil))
    (aperture--log "should not appear")
    (should (null (get-buffer aperture-log-buffer)))))

(ert-deftest aperture-test-log-records-when-enabled ()
  (when-let* ((buf (get-buffer aperture-log-buffer))) (kill-buffer buf))
  (unwind-protect
      (let ((aperture-debug t))
        (aperture--log "hello %s" 'world)
        (with-current-buffer aperture-log-buffer
          (should (string-match-p "hello world" (buffer-string)))))
    (when-let* ((buf (get-buffer aperture-log-buffer))) (kill-buffer buf))))

(ert-deftest aperture-test-log-abbrev-keeps-one-line ()
  "Candidates arrive propertized and may span lines; a log line may not."
  (should (equal (aperture--log-abbrev (propertize "a\nb" 'face 'bold)) "a\\nb"))
  (should (equal (aperture--log-abbrev "abcdef" 3) "abc...")))

(ert-deftest aperture-test-log-window-tolerates-dead-window ()
  (should (equal (aperture--log-window nil) "none")))

(ert-deftest aperture-test-log-result-distinguishes-kinds ()
  (should (string-match-p "buffer=" (aperture--log-result '(:buffer "x"))))
  (should (string-match-p "content=2 chars" (aperture--log-result '(:content "hi")))))

(provide 'aperture-test)
;;; aperture-test.el ends here
