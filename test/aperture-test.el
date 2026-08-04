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
