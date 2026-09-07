;;; spike-posframe.el --- Child-frame layout spike for aperture -*- lexical-binding: t -*-

;; Launch with:  make spike        (needs GUI Emacs and DEPS)
;;
;; The M4 spike (docs/DESIGN.md section 3.4b).  Self-contained on purpose: it
;; does not touch aperture, and it stays in the tree because batch cannot reach
;; any of what it checks, so it is the only executable record of the
;; child-frame layout working.
;;
;; THE DECISIVE QUESTION IS B3.  `with-selected-window' on a window in another
;; frame selects that frame; `minibuffer-follows-selected-frame' defaults to t
;; and can relocate an active minibuffer onto a newly selected frame.  If that
;; fires, the layout is dead.
;;
;; Parts A (structure) and B (live minibuffer) run on startup and write
;; PASS/FAIL to *spike* and to spike-results.txt.  Parts D and E drive a real
;; vertico session and a real `consult-line' over a named Emacs server; run
;; them with `M-x spike-de'.  Part C leaves a working prototype to drive by
;; hand.

;;; Code:

(require 'vertico)
(require 'vertico-buffer)
(require 'consult nil t)
(require 'server)

(defvar spike-dir
  (file-name-directory (or load-file-name buffer-file-name default-directory))
  "Directory of this file.
Derived rather than assumed: launched via `open -a Emacs.app' the
process inherits no useful `default-directory'.")
(defvar spike-file (expand-file-name "spike-results.txt" spike-dir))
(defvar spike-results nil)
(defvar spike-frame nil "The child frame, while a session is live.")
(defvar spike-list-win nil)
(defvar spike-pane nil)
(defvar spike-parent nil)
(defvar spike-orig-win nil)

(defun spike-log (fmt &rest args)
  (let ((s (apply #'format fmt args)))
    (push s spike-results)
    (write-region (concat s "\n") nil spike-file 'append 'silent)))

(defun spike-check (label ok &optional detail)
  (spike-log "%-5s %-52s %s" (if ok "PASS" "FAIL") label (or detail "")))

;;;; The child frame

(defun spike-make-frame (parent)
  "Create the aperture child frame on PARENT and split it.
Borrowing PARENT's minibuffer window is what keeps the child frame from
wanting a minibuffer of its own -- and is the property B3 is testing."
  (let* ((fw (frame-pixel-width parent))
         (fh (frame-pixel-height parent))
         (w (round (* fw 0.86)))
         (h (round (* fh 0.62)))
         (frame-resize-pixelwise t)
         (f (make-frame
             `((parent-frame . ,parent)
               (minibuffer . ,(minibuffer-window parent))
               (undecorated . t)
               (no-accept-focus . t)
               (no-focus-on-map . t)
               (no-other-frame . t)
               (desktop-dont-save . t)
               (internal-border-width . 1)
               (child-frame-border-width . 1)
               (left-fringe . 8)
               (right-fringe . 8)
               (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (menu-bar-lines . 0)
               (tool-bar-lines . 0)
               (tab-bar-lines . 0)
               (unsplittable . nil)
               (visibility . nil)))))
    (set-frame-size f w h t)
    (set-frame-position f (round (/ (- fw w) 2)) (round (/ (- fh h) 3)))
    (setq spike-frame f)
    ;; Left = candidate list (the minibuffer buffer, placed by vertico-buffer),
    ;; right = preview pane.  Splitting `right' leaves the ROOT window on the
    ;; left, which is what vertico-buffer will be pointed at.
    (let* ((root (frame-root-window f))
           (right (split-window root (round (* (window-width root) 0.5)) 'right)))
      (setq spike-list-win root
            spike-pane right)
      (set-window-buffer spike-pane (get-buffer-create "*spike pane*"))
      (dolist (w (list spike-list-win spike-pane))
        (set-window-parameter w 'no-other-window t)))
    (make-frame-visible f)
    f))

(defun spike-kill-frame ()
  (when (frame-live-p spike-frame) (delete-frame spike-frame))
  (setq spike-frame nil spike-list-win nil spike-pane nil))

;;;; Part A -- structural, no minibuffer

(defun spike-part-a ()
  (setq spike-parent (selected-frame)
        spike-orig-win (selected-window))
  (spike-log "\n=== Part A: structure (%s, %s) ===" emacs-version system-type)
  (let ((f (spike-make-frame spike-parent)))
    (spike-check "A1 child frame is a child of the parent"
                 (eq (frame-parent f) spike-parent))
    (spike-check "A2 child frame borrows parent's minibuffer window"
                 (eq (window-frame (minibuffer-window f)) spike-parent))
    (spike-check "A3 child frame splits into two live windows"
                 (and (window-live-p spike-list-win) (window-live-p spike-pane)
                      (not (eq spike-list-win spike-pane))
                      (eq (window-frame spike-pane) f)))
    ;; A4: does with-selected-window hop the selected FRAME?  Everything in
    ;; consult's preview path depends on this working.
    (let (inside-frame inside-win)
      (with-selected-window spike-pane
        (setq inside-frame (selected-frame) inside-win (selected-window)))
      (spike-check "A4 with-selected-window selects the child frame"
                   (and (eq inside-frame f) (eq inside-win spike-pane))
                   (format "selected-frame was %s"
                           (if (eq inside-frame f) "child" "PARENT -- redirect impossible"))))
    (spike-check "A5 selected frame restored afterwards"
                 (eq (selected-frame) spike-parent))
    ;; A6: get-buffer-window has no ALL-FRAMES arg in consult--jump-ensure-buffer
    ;; (consult.el:1573), so from inside the child frame it must not see the
    ;; parent's window showing the same buffer.  That is what would make
    ;; aperture-consult.el unnecessary in this layout.
    (let ((shared (get-buffer-create "*spike shared*")))
      (set-window-buffer spike-orig-win shared)
      (set-window-buffer spike-pane shared)
      (with-selected-window spike-pane
        (let ((w (get-buffer-window shared)))
          (spike-check "A6 get-buffer-window from child sees only child windows"
                       (and w (eq (window-frame w) f))
                       (format "found %s" (if w (if (eq (window-frame w) f) "child" "PARENT") "nothing"))))))
    ;; A7: consult acts on (selected-window) inside with-selected-window; the
    ;; pane must accept switch-to-buffer.
    (with-selected-window spike-pane
      (switch-to-buffer (get-buffer-create "*spike target*") 'norecord))
    (spike-check "A7 switch-to-buffer lands in the child pane"
                 (equal (buffer-name (window-buffer spike-pane)) "*spike target*")
                 (format "pane shows %s" (buffer-name (window-buffer spike-pane))))
    (set-window-buffer spike-orig-win (get-buffer-create "*spike*"))))

;;;; Part B -- inside a live minibuffer

(defun spike-part-b-checks ()
  (spike-log "\n=== Part B: live minibuffer ===")
  (spike-log "      minibuffer-follows-selected-frame = %S" minibuffer-follows-selected-frame)
  (condition-case e
      (let ((mb-before (window-frame (active-minibuffer-window)))
            (msw-before (minibuffer-selected-window))
            inside-mb-frame inside-msw inside-sel-frame)
        (spike-check "B1 minibuffer-selected-window is the original window"
                     (eq msw-before spike-orig-win))
        (spike-check "B2 active minibuffer lives on the parent frame"
                     (eq mb-before spike-parent))
        (with-selected-window spike-pane
          (setq inside-sel-frame (selected-frame)
                inside-mb-frame (window-frame (active-minibuffer-window))
                inside-msw (minibuffer-selected-window))
          (switch-to-buffer (get-buffer-create "*spike preview*") 'norecord))
        ;; *** THE DECISIVE ONE ***
        (spike-check "B3 minibuffer does NOT move to the child frame"
                     (eq inside-mb-frame spike-parent)
                     (if (eq inside-mb-frame spike-parent)
                         "stayed on parent"
                       "MOVED -- child-frame layout is not viable"))
        (spike-check "B4 selected frame really was the child during the hop"
                     (eq inside-sel-frame spike-frame))
        ;; `minibuffer-selected-window' returns nil unless the SELECTED window
        ;; is a minibuffer window, so it is nil inside any
        ;; `with-selected-window'.  B4c is the control proving that is generic
        ;; behaviour and not something the child frame causes.  It matters
        ;; because `consult--original-window' falls through to
        ;; `(selected-window)' in exactly that case -- which is the pane, so
        ;; re-entrant calls stay self-consistent.
        (let (control)
          (with-selected-window spike-orig-win
            (setq control (minibuffer-selected-window)))
          (spike-check "B4b msw nil during hop == nil in a PARENT window too"
                       (eq (null inside-msw) (null control))
                       (format "child=%S parent-control=%S" inside-msw control)))
        (spike-check "B5 preview switch-to-buffer landed in the pane"
                     (equal (buffer-name (window-buffer spike-pane)) "*spike preview*")
                     (format "pane shows %s" (buffer-name (window-buffer spike-pane))))
        (spike-check "B6 minibuffer-selected-window unchanged after the hop"
                     (eq (minibuffer-selected-window) msw-before)
                     (format "%S" (minibuffer-selected-window)))
        (spike-check "B7 minibuffer still on the parent frame afterwards"
                     (eq (window-frame (active-minibuffer-window)) spike-parent))
        (spike-check "B8 original window's buffer untouched by preview"
                     (equal (buffer-name (window-buffer spike-orig-win)) "*spike*")
                     (format "shows %s" (buffer-name (window-buffer spike-orig-win)))))
    (error (spike-log "FAIL  B* signalled: %S" e))))

(defun spike-part-b ()
  (minibuffer-with-setup-hook
      (lambda ()
        (run-with-timer
         0.4 nil
         (lambda ()
           (spike-part-b-checks)
           (spike-log "\n(Part B done. If the minibuffer did not close itself, press C-g.)")
           (run-with-timer 0.1 nil (lambda () (ignore-errors (abort-recursive-edit)))))))
    ;; `abort-recursive-edit' arrives here as a `quit' signal, which
    ;; `ignore-errors' does NOT catch -- it only handles `error'.  Letting it
    ;; through unwinds the caller, so nothing after Part B ever runs.
    (condition-case nil (read-from-minibuffer "spike (closes itself): ")
      ((quit error) nil)))
  (spike-kill-frame))

;;;; Part C -- the prototype, driven by hand

(defvar spike-session nil)

(defun spike-c-setup (&rest _)
  "Build the child-frame layout for this minibuffer.
Mirrors `aperture--setup': :before advice on `vertico--setup', which is
after `minibuffer-completion-table' is set and before vertico-buffer
picks its window."
  (setq spike-parent (window-frame (minibuffer-window))
        spike-orig-win (minibuffer-selected-window))
  (when (window-live-p spike-orig-win)
    (spike-make-frame spike-parent)
    (setq-local spike-session t)
    (add-hook 'minibuffer-exit-hook #'spike-c-teardown 90 t)))

(defun spike-c-teardown ()
  (setq spike-session nil)
  (spike-kill-frame))

(defun spike-c-place-list (fn &rest args)
  "Around `vertico-buffer--setup': force the list into the child frame."
  (if (and spike-session (window-live-p spike-list-win))
      (let ((display-buffer-overriding-action
             (list (lambda (buffer _alist)
                     (set-window-buffer spike-list-win buffer)
                     spike-list-win))))
        (apply fn args))
    (apply fn args)))

(defun spike-c-original-window (fn)
  "Around `consult--original-window': redirect preview into the pane.
This is the single chokepoint -- every consult preview path runs inside
`with-selected-window (consult--original-window)' and then acts on
`(selected-window)'."
  (if (and (window-live-p spike-pane)
           (when-let* ((w (active-minibuffer-window)))
             (buffer-local-value 'spike-session (window-buffer w))))
      spike-pane
    (funcall fn)))

(defun spike-install ()
  "Install the prototype.  Called at startup."
  (advice-add 'vertico--setup :before #'spike-c-setup)
  (advice-add 'vertico-buffer--setup :around #'spike-c-place-list)
  (when (fboundp 'consult--original-window)
    (advice-add 'consult--original-window :around #'spike-c-original-window))
  ;; Condition 3 rehearsal: suppress a foreign display extension for OUR
  ;; sessions only, never touching its global mode.  `&context' re-resolves
  ;; per call and honours dynamic binding, so this is the shape aperture would
  ;; use for vertico-posframe.
  (when (fboundp 'vertico-posframe-mode-workable-p)
    (advice-add 'vertico-posframe-mode-workable-p :around
                (lambda (fn) (and (not spike-session) (funcall fn)))))
  ;; See the note in `spike-e-consult-line': without this, driving
  ;; `consult-line' by hand in this `emacs -Q' matches nothing.
  (setq completion-styles '(basic substring))
  (vertico-mode 1)
  (vertico-buffer-mode 1))

;;;; Part D -- live vertico session, driven over the server
;;
;; These are the checks that decide conditions 1 and 2, and they need a real
;; completion session.  Each runs one, inspects it from a timer, then aborts
;; it, so the whole part is non-interactive and writes to `spike-file'.

(defun spike-d-vertico ()
  "Check the child-frame layout during a real vertico session."
  (interactive)
  (spike-log "\n=== Part D: live vertico session ===")
  (minibuffer-with-setup-hook
      (lambda ()
        (run-with-timer
         0.6 nil
         (lambda ()
           (condition-case e
               (let* ((mbwin (active-minibuffer-window))
                      (mb (window-buffer mbwin))
                      (ov-win (and (overlayp vertico--candidates-ov)
                                   (overlay-get vertico--candidates-ov 'window)))
                      (lbuf (and (window-live-p spike-list-win)
                                 (window-buffer spike-list-win))))
                 (spike-check "D1 child frame live and visible mid-session"
                              (and (frame-live-p spike-frame)
                                   (frame-visible-p spike-frame)))
                 (spike-check "D2 list window shows the minibuffer buffer"
                              (eq lbuf mb)
                              (format "shows %s" (and lbuf (buffer-name lbuf))))
                 (spike-check "D3 vertico candidates overlay targets the child list window"
                              (eq ov-win spike-list-win)
                              (format "%S" ov-win))
                 ;; Condition 1: the prompt and the typed input are IN the
                 ;; child frame, at the top of the list window, above the
                 ;; candidates -- not stranded in the parent's minibuffer.
                 (let ((head (with-current-buffer mb
                               (buffer-substring-no-properties
                                (point-min) (min (point-max) (+ (point-min) 24))))))
                   (spike-check "D4 prompt+input are in the list window's buffer"
                                (string-prefix-p "spike-probe:" head)
                                (format "starts %S" head)))
                 (spike-check "D4b list window is scrolled to show it (not past it)"
                              (= (window-start spike-list-win)
                                 (with-current-buffer mb (point-min)))
                              (format "window-start=%S point-min=%S"
                                      (window-start spike-list-win)
                                      (with-current-buffer mb (point-min))))
                 (spike-check "D5 a cursor will be drawn in the list window"
                              (buffer-local-value 'cursor-in-non-selected-windows mb)
                              (format "cursor-in-non-selected-windows=%S"
                                      (buffer-local-value 'cursor-in-non-selected-windows mb)))
                 (spike-check "D6 parent minibuffer window is collapsed"
                              (< (window-pixel-height mbwin) (* 2 (default-line-height)))
                              (format "%dpx" (window-pixel-height mbwin)))
                 (spike-check "D7 vertico-count sized from the child window"
                              (> (buffer-local-value 'vertico-count mb) 3)
                              (format "vertico-count=%S"
                                      (buffer-local-value 'vertico-count mb)))
                 (when (fboundp 'consult--original-window)
                   (spike-check "D8 consult--original-window resolves to the pane"
                                (eq (consult--original-window) spike-pane)
                                (format "%S" (consult--original-window)))))
             (error (spike-log "FAIL  D* signalled: %S" e)))
           (run-with-timer 0.1 nil (lambda () (ignore-errors (abort-recursive-edit)))))))
    (condition-case nil
        (completing-read "spike-probe: " '("alpha" "beta" "gamma" "delta" "epsilon") nil t)
      ((quit error) nil)))
  (spike-log "(Part D done.)"))

(defun spike-e-consult-line ()
  "End-to-end: does consult preview land in the child pane?  Condition 2."
  (interactive)
  (spike-log "\n=== Part E: consult-line end to end ===")
  (if (not (fboundp 'consult-line))
      (spike-log "SKIP  consult not loaded")
    (with-current-buffer (get-buffer-create "*spike prose*")
      (erase-buffer)
      (dotimes (i 200) (insert (format "line %d needle-%d\n" i i)))
      (goto-char (point-min)))
    (switch-to-buffer "*spike prose*")
    (minibuffer-with-setup-hook
        (lambda ()
          ;; Stand in for typing.  Inserting alone is NOT enough: consult
          ;; drives preview from `post-command-hook', which a timer does not
          ;; run.  Drive the two steps the command loop would have done, so
          ;; this tests consult's preview path rather than the command loop.
          (run-with-timer
           0.4 nil
           (lambda ()
             (ignore-errors
               (insert "needle-150")
               (when (fboundp 'vertico--exhibit) (vertico--exhibit))
               (when (bound-and-true-p consult--preview-function)
                 (funcall consult--preview-function)))))
          (run-with-timer
           1.6 nil
           (lambda ()
             (condition-case e
                 (let ((pb (and (window-live-p spike-pane) (window-buffer spike-pane))))
                   (spike-check "E1 preview buffer is in the CHILD pane"
                                (eq pb (get-buffer "*spike prose*"))
                                (format "pane shows %s" (and pb (buffer-name pb))))
                   (spike-check "E2 pane scrolled to the match, not line 1"
                                (and (eq pb (get-buffer "*spike prose*"))
                                     (> (window-point spike-pane) 1000))
                                (format "window-point=%S" (window-point spike-pane)))
                   (spike-check "E3 parent frame not hijacked by the preview"
                                (eq (window-frame (active-minibuffer-window)) spike-parent))
                   (spike-check "E4 pane's window-start followed the match"
                                (> (window-start spike-pane) 1)
                                (format "window-start=%S" (window-start spike-pane)))
                   (spike-check "E5 parent's window still shows the prose unscrolled"
                                (= (window-point spike-orig-win) 1)
                                (format "window-point=%S" (window-point spike-orig-win))))
               (error (spike-log "FAIL  E* signalled: %S" e)))
             (run-with-timer 0.1 nil (lambda () (ignore-errors (abort-recursive-edit)))))))
      ;; `emacs -Q' defaults to the `basic' completion style, which is
      ;; prefix-only: "needle-150" never matches "line 150 needle-150" and the
      ;; candidate list comes back empty, which looks exactly like a broken
      ;; preview.  Real users have orderless or substring; say so explicitly
      ;; rather than debug it twice.
      (let ((completion-styles '(basic substring)))
        (condition-case nil (consult-line) ((quit error) nil)))))
  (spike-log "(Part E done.)"))

(defun spike-de ()
  "Run parts D and E back to back."
  (interactive)
  (spike-d-vertico)
  (run-with-timer 0.5 nil #'spike-e-consult-line))

;;;; Driver

(defun spike-report ()
  (with-current-buffer (get-buffer-create "*spike*")
    (erase-buffer)
    (insert "aperture child-frame spike\n==========================\n\n")
    (insert (mapconcat #'identity (reverse spike-results) "\n"))
    (insert "\n\n")
    (insert (format "Results also in %s\n\n" spike-file))
    (insert "Part C -- drive these by hand in the child frame:\n\n")
    (insert "  M-x                  does the child frame show PROMPT + INPUT at the\n")
    (insert "                       top of the left window, with candidates below?\n")
    (insert "                       (condition 1)  Is there a visible cursor there?\n")
    (insert "  C-x C-f              same, and does typing update it live?\n")
    (insert "  M-x consult-line     does preview land in the RIGHT window of the\n")
    (insert "                       child frame, not in the parent frame? (condition 2)\n")
    (insert "  M-x consult-ripgrep  hits in several files -- all previewing in the pane?\n")
    (insert "  C-g and RET          does the child frame always disappear?\n\n")
    (insert "Watch for: flicker, the child frame stealing focus, the cursor drawn in\n")
    (insert "the parent's minibuffer instead of the child frame, or the frame\n")
    (insert "surviving an abort.\n")
    (goto-char (point-min)))
  (switch-to-buffer "*spike*"))

(defun spike-run ()
  (ignore-errors (delete-file spike-file))
  (setq spike-results nil)
  (condition-case e
      (progn (spike-part-a) (spike-part-b))
    (error (spike-log "FATAL: %S" e)))
  (spike-kill-frame)
  (spike-install)
  ;; A server, so the live-session checks can be driven from outside instead
  ;; of read off the screen by hand.  Named, so it cannot collide with a real
  ;; Emacs server.
  (setq server-name "aperture-spike")
  (condition-case e (progn (server-start) (spike-log "\nserver: started as %S" server-name))
    (error (spike-log "\nserver: FAILED %S" e)))
  (spike-report)
  (spike-log "spike-run complete; Part C installed.")
  (let ((fails (seq-count (lambda (s) (string-prefix-p "FAIL" s)) spike-results)))
    (message "spike: %s -- see *spike*"
             (if (zerop fails) "all checks passed" (format "%d CHECK(S) FAILED" fails)))))

;; Startup must be deferred: Part B needs a live, displayed frame to create a
;; child frame on, which does not exist while this file is being loaded.
(run-with-idle-timer 0.5 nil #'spike-run)

;;; spike-posframe.el ends here
