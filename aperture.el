;;; aperture.el --- Rich per-candidate preview pane for completion -*- lexical-binding: t -*-

;; Copyright (C) 2026 Matt Sawyer

;; Author: Matt Sawyer
;; Version: 0.3.1
;; Package-Requires: ((emacs "29.1") (vertico "1.7"))
;; Keywords: convenience, matching
;; URL: https://github.com/mattsawyer77/aperture.el
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; aperture renders arbitrary, multi-line, fontified context for the selected
;; completion candidate in a pane, dispatched on the candidate's completion
;; category, and working for any `completing-read'.
;;
;;     +---------------------------------------+
;;     |  original buffer - stays visible      |
;;     +-------------------+-------------------+
;;     |  candidate list   |  preview pane     |  <- aperture-height
;;     +-------------------+-------------------+
;;     |  minibuffer                           |
;;     +---------------------------------------+
;;
;; The pane is `minibuffer-selected-window', so consult previews into it with
;; no interception.  `aperture-display' selects a second, opt-in layout that
;; floats the whole UI in a child frame instead; see `aperture-child-frame.el'.
;;
;; Design notes: docs/DESIGN.md.

;;; Code:

(require 'cl-lib)
(require 'seq)

(declare-function aperture-vertico-install "aperture-vertico")
(declare-function aperture-vertico-uninstall "aperture-vertico")
(declare-function aperture-consult-install "aperture-consult")
(declare-function aperture-child-frame--build "aperture-child-frame")
(declare-function aperture-consult-uninstall "aperture-consult")
(defvar consult--preview-function)

(defgroup aperture nil
  "Rich per-candidate preview pane for completion."
  :group 'convenience
  :prefix "aperture-")

;;;; Customization

(defcustom aperture-key 'any
  "When to update the preview pane.

Grammar mirrors `consult-preview-key':

  nil                     never preview; pane stays closed
  any                     preview on every selection change
  KEY                     preview only when KEY is pressed
  (KEY...)                preview on any of these keys
  (:debounce SECS any)    preview live, with SECS debounce"
  :type '(choice (const :tag "Any key" any)
          (list :tag "Debounced" (const :debounce) (float :tag "Seconds")
                (const any))
          (const :tag "No preview" nil)
          (key :tag "Key")
          (repeat :tag "List of keys" key)))

(defcustom aperture-delay 0.15
  "Idle debounce before rendering a preview, in seconds.
Ignored for previewers declaring `:cost free'."
  :type 'number)

(defcustom aperture-height 0.5
  "Height of the whole aperture area: list and pane together.
An integer is a number of lines; a float is a fraction of the window
being split."
  :type '(choice integer float))

(defcustom aperture-min-top-height 4
  "Minimum lines left for the original buffer above the aperture area.
If the frame cannot spare this, the top split is skipped rather than
producing an unusable sliver."
  :type 'integer)

(defcustom aperture-side 'right
  "Which side of the aperture area holds the preview pane."
  :type '(choice (const right) (const left)))

(defcustom aperture-display 'window
  "Where the aperture layout is drawn.

`window'\=' carves the layout out of the window completion was invoked
from, leaving that buffer visible above it.  The default, and the only
layout that works on a TTY.

`child-frame'\=' floats the whole layout in a child frame over the parent,
leaving every one of your windows visible behind it.  Needs a graphical
display; degrades to `window'\=' with a line in the log without one."
  :type '(choice (const :tag "Split the current window" window)
          (const :tag "Float in a child frame" child-frame)))

(defcustom aperture-width 0.5
  "Width of the preview pane within the aperture area.
An integer is columns; a float is a fraction."
  :type '(choice integer float))

(defcustom aperture-min-pane-width 40
  "Pane width, in columns, below which aperture will try to get more room.

A trigger, not a guarantee.  When the window being split cannot give the
pane this many columns *and* deleting that window's side-by-side siblings
would help, the session takes the whole frame instead: those siblings are
deleted, the usual splits follow, and the previous window configuration
is restored when the session ends.

Nothing happens when widening is impossible: a frame that is simply
narrow, a sole window, or windows stacked above and below rather than
beside (they are already full width).  In those cases the pane stays as
narrow as the frame dictates.

Windows carrying the `no-delete-other-windows' parameter, which is what
sidebars such as treemacs set, survive regardless.

nil disables this and always splits in place, however narrow the result.
A value at or above your frame width makes it unconditional.

Does not apply when `aperture-display' is `child-frame'\=': that frame's
size is set directly by `aperture-child-frame-width'.  A pane that still
comes out under this width is logged."
  :type '(choice natnum (const :tag "Never take the frame" nil)))

(defcustom aperture-partial-size (* 1024 1024)
  "Files larger than this are previewed partially rather than refused."
  :type 'natnum)

(defcustom aperture-partial-chunk (* 10 1024)
  "Bytes read from the head of an oversized file."
  :type 'natnum)

(defcustom aperture-excluded-files
  '("\\.gpg\\'" "\\.\\(?:jpe?g\\|png\\|gif\\|pdf\\|zip\\|gz\\|elc\\)\\'")
  "Regexps matching files that must not be previewed.
Remote files are excluded separately and unconditionally; a synchronous
TRAMP read is the one failure mode debouncing cannot rescue."
  :type '(repeat regexp))

(defcustom aperture-excluded-buffers '("\\` ")
  "Regexps matching buffer names that must not be previewed."
  :type '(repeat regexp))

(defcustom aperture-max-count 10
  "Maximum number of preview buffers kept alive during a session."
  :type 'natnum)

(defcustom aperture-previewer-registry
  '((symbol      . aperture-preview-symbol)
    (function    . aperture-preview-symbol)
    (variable    . aperture-preview-symbol)
    (command     . aperture-preview-symbol)
    (face        . aperture-preview-symbol)
    (file        . aperture-preview-file)
    (project-file . aperture-preview-project-file)
    (buffer      . aperture-preview-buffer)
    (kill-ring   . aperture-preview-kill-ring)
    (package     . aperture-preview-package)
    (bookmark    . aperture-preview-bookmark))
  "Alist mapping completion category to previewer function.
Mirrors `marginalia-annotator-registry' so it is familiar."
  :type '(alist :key-type symbol :value-type function))

(defcustom aperture-command-previewers nil
  "Alist mapping command symbol to previewer function.
Takes precedence over `aperture-previewer-registry', because the command
is often more specific than the category."
  :type '(alist :key-type symbol :value-type function))

(defcustom aperture-consult-categories
  '(consult-location consult-grep consult-xref consult-compile-error
    consult-flymake-error consult-info org-heading imenu multi-category)
  "Categories where consult drives preview itself.
aperture opens the pane for these so the geometry is right, then stands
down and lets consult render into it.

An entry belongs here when consult passes a `:state' built on
`consult--jump-preview' for that category and aperture has no previewer
of its own.  Categories aperture also handles -- `file', `buffer',
`bookmark', `kill-ring' -- hand over at run time instead, through
`aperture--consult-owns-p'.

`imenu' is the one entry a non-consult command can also produce: plain
`\\[imenu]' is classified into it by marginalia, and the pane then opens
with nothing to render."
  :type '(repeat symbol))

(defcustom aperture-prompt-categories
  '(("\\<package\\>"  . package)
    ("\\<bookmark\\>" . bookmark))
  "Fallback alist of minibuffer prompt regexp to completion category.

Consulted only when the completion table declares no category, and
matched case-insensitively.  Several built-in commands -- notably
`describe-package', `package-install' and `bookmark-jump' -- call
`completing-read' on a bare list of strings, so their metadata carries
nothing to dispatch on.

Where marginalia is active its own classifier answers first, through
`:before-until' advice on `completion-metadata-get', and this variable is
never reached."
  :type '(alist :key-type regexp :value-type symbol))

(defface aperture-suppressed '((t :inherit shadow))
  "Face for messages explaining why a preview was suppressed.")

;;;; Debug logging

(defcustom aperture-debug nil
  "When non-nil, record session activity in `aperture-log-buffer'.
Records where a session declined to start and where its windows landed.
See `aperture-show-log'."
  :type 'boolean)

(defconst aperture-log-buffer "*aperture-log*"
  "Name of the buffer `aperture-debug' writes to.")

(defun aperture--log-buffer ()
  "Return the log buffer, creating and initializing it if necessary."
  (or (get-buffer aperture-log-buffer)
      (with-current-buffer (get-buffer-create aperture-log-buffer)
        (special-mode)
        ;; Make window points advance with insertions at the end, so a
        ;; displayed log follows the tail while a session is running.
        (setq-local window-point-insertion-type t)
        (current-buffer))))

(defun aperture--log (format-string &rest args)
  "Append FORMAT-STRING formatted with ARGS to the log.
Does nothing unless `aperture-debug' is non-nil.  Lines are prefixed
with a timestamp and the minibuffer depth, so recursive sessions can be
told apart."
  (when aperture-debug
    (let ((line (apply #'format format-string args))
          (depth (minibuffer-depth)))
      (with-current-buffer (aperture--log-buffer)
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char (point-max))
            (insert (format-time-string "%H:%M:%S.%3N ")
                    (format "d%d " depth)
                    line "\n")))))))

(defun aperture--log-abbrev (object &optional limit)
  "Format OBJECT as a single log-safe line of at most LIMIT characters.
Candidates arrive propertized and may contain newlines; neither belongs
in a log."
  (let* ((limit (or limit 50))
         (s (substring-no-properties (format "%s" object)))
         (s (if (> (length s) limit) (concat (substring s 0 limit) "...") s)))
    (string-replace "\n" "\\n" s)))

(defun aperture--log-window (win)
  "Describe WIN, with its dimensions, for the log."
  (if (window-live-p win)
      (format "%s %dx%d" win (window-width win) (window-height win))
    "none"))

(defun aperture--log-result (plist)
  "Describe a normalized previewer result PLIST for the log."
  (cond
   ((plist-get plist :buffer) (format "buffer=%s" (plist-get plist :buffer)))
   ((plist-get plist :content)
    (format "content=%d chars mode=%s goto=%s"
            (length (plist-get plist :content))
            (or (plist-get plist :mode) (plist-get plist :file) "-")
            (or (plist-get plist :goto) "-")))
   (t "unrecognized")))

;;;###autoload
(defun aperture-show-log ()
  "Display the aperture debug log, enabling logging if it is off."
  (interactive)
  (unless aperture-debug
    (setq aperture-debug t)
    (message "aperture: logging enabled; reproduce the problem now"))
  (pop-to-buffer (aperture--log-buffer)))

;;;; Session state

(cl-defstruct (aperture--session (:constructor aperture--session-make)
                                 (:copier nil))
  pane pane-buffer list-win top-win config expanded frame minibuffer-overlay
  (generation 0) timer cancel last-key previewer consult-owned buffers)

(defvar-local aperture--session nil
  "Active `aperture--session' for this minibuffer, if any.")

(defvar aperture-frontend nil
  "Plist describing the active completion frontend.
Keys `:active-p', `:candidate', `:index', each a function of no
arguments.  Set by `aperture-vertico'.")

(defun aperture--frontend (key)
  "Call the frontend function under KEY, or return nil."
  (when-let* ((fn (plist-get aperture-frontend key)))
    (funcall fn)))

(defun aperture--active-session ()
  "Return the session of the innermost active minibuffer, or nil.
Reached through the minibuffer window rather than the current buffer,
which during a consult preview is the previewed one."
  (when-let* ((win (active-minibuffer-window))
              (buf (window-buffer win))
              ((buffer-live-p buf)))
    (buffer-local-value 'aperture--session buf)))

(defun aperture--call-in-active-minibuffer (fn &rest args)
  "Call FN with ARGS while the active minibuffer buffer is current.

Aperture creates a child frame while Vertico is setting up.  Some Emacs
builds let that creation change `current-buffer' to the source buffer,
although the active minibuffer is unchanged.  Callers that install or
read minibuffer-local state use this to retain the correct context."
  (if-let* ((win (active-minibuffer-window))
            (buf (window-buffer win))
            ((buffer-live-p buf)))
      (with-current-buffer buf
        (apply fn args))
    (apply fn args)))

;;;; Preview key grammar

(defun aperture--key-normalize (spec)
  "Normalize SPEC into (KEYS . DEBOUNCE).
KEYS is t for live preview, nil for never, or a list of key strings."
  (cond
   ((null spec) (cons nil 0))
   ((eq spec 'any) (cons t aperture-delay))
   ((and (consp spec) (eq (car spec) :debounce))
    (cons (if (memq 'any spec) t (cddr spec)) (cadr spec)))
   ((stringp spec) (cons (list spec) 0))
   ((consp spec) (cons spec 0))
   (t (cons t aperture-delay))))

(defun aperture--live-p ()
  "Non-nil if the current settings preview on every selection change."
  (eq t (car (aperture--key-normalize aperture-key))))

(defun aperture--cost (fn)
  "Declared cost of previewer FN: `free', `cheap' or `expensive'."
  (or (and (symbolp fn) (get fn 'aperture-cost)) 'cheap))

(defun aperture--delay-for (fn)
  "Debounce delay in seconds for previewer FN."
  (pcase (aperture--cost fn)
    ('free 0)
    ('expensive (* 3 (cdr (aperture--key-normalize aperture-key))))
    (_ (cdr (aperture--key-normalize aperture-key)))))

;;;; Dispatch

(defun aperture--classify-prompt (prompt)
  "Category PROMPT matches in `aperture-prompt-categories', or nil.
Matched case-insensitively, as marginalia does."
  (let ((case-fold-search t))
    (cl-loop for (re . cat) in aperture-prompt-categories
             when (string-match-p re prompt) return cat)))

(defun aperture--prompt-category ()
  "Category guessed from the minibuffer prompt, or nil.
See `aperture-prompt-categories'."
  (when (minibufferp)
    (aperture--classify-prompt (or (minibuffer-prompt) ""))))

(defun aperture--category ()
  "Completion category of the active minibuffer, or nil."
  (when minibuffer-completion-table
    (or (ignore-errors
          (completion-metadata-get
           (completion-metadata
            (buffer-substring-no-properties (minibuffer-prompt-end) (point-max))
            minibuffer-completion-table minibuffer-completion-predicate)
           'category))
        (aperture--prompt-category))))

(defun aperture--previewer-for (category command)
  "Resolve a previewer for CATEGORY and COMMAND, or nil.
Command overrides beat the category registry."
  (or (alist-get command aperture-command-previewers)
      (alist-get category aperture-previewer-registry)))

(defun aperture--normalize (result)
  "Canonicalize a previewer RESULT into a plist, or nil.

  nil       -> nil
  string    -> (:content STRING)
  plist     -> itself
  function  -> (:async FUNCTION)"
  (cond
   ((null result) nil)
   ((stringp result) (list :content result))
   ((and (consp result) (keywordp (car result))) result)
   ((functionp result) (list :async result))
   (t (error "Invalid aperture previewer result: %S" result))))

;;;; Guards

(defun aperture--excluded-p (name regexps)
  "Non-nil if NAME matches any of REGEXPS."
  (seq-some (lambda (re) (string-match-p re name)) regexps))

(defun aperture-file-guard (file)
  "Return a suppression message for FILE, or nil if it may be previewed.
Exposed to previewers so the policy lives in one place."
  (cond
   ((file-remote-p file)
    "Preview suppressed: remote file")
   ((aperture--excluded-p file aperture-excluded-files)
    "Preview suppressed: matches `aperture-excluded-files'")
   ((not (file-readable-p file))
    "Preview unavailable: not readable")))

(defun aperture-insert-file (file)
  "Insert FILE into the current buffer, partially if it is large.
Returns non-nil when the read was truncated."
  (let* ((size (file-attribute-size (file-attributes file)))
         (partial (and size (> size aperture-partial-size))))
    (if partial
        (insert-file-contents file nil 0 aperture-partial-chunk)
      (insert-file-contents file))
    partial))

(defmacro aperture--with-guards (&rest body)
  "Run BODY with previewing made incapable of prompting or side effects."
  (declare (indent 0) (debug t))
  `(let ((non-essential t)
         (enable-local-variables nil)
         (enable-dir-local-variables nil)
         (inhibit-message t)
         (delay-mode-hooks t))
     ,@body))

;;;; Rendering

(defun aperture--content-buffer (session)
  "Return the buffer aperture renders content into for SESSION."
  (let ((buf (get-buffer-create " *aperture*")))
    (cl-pushnew buf (aperture--session-buffers session))
    buf))

(defun aperture--apply-mode (plist)
  "Apply the `:mode' or `:file' of PLIST to the current buffer."
  (let ((mode (plist-get plist :mode))
        (file (plist-get plist :file)))
    (ignore-errors
      (cond (mode (funcall mode))
            (file (let ((buffer-file-name file))
                    (set-auto-mode)))))
    (ignore-errors (font-lock-ensure))))

(defun aperture--apply-position (plist window)
  "Apply `:goto' and `:highlight' from PLIST within WINDOW."
  (when-let* ((goto (plist-get plist :goto)))
    (goto-char (point-min))
    (if (integerp goto) (forward-line (1- goto)) (goto-char goto))
    (when (window-live-p window)
      (set-window-point window (point))
      (with-selected-window window (recenter))))
  (pcase-dolist (`(,beg . ,end) (plist-get plist :highlight))
    (let ((ov (make-overlay beg end)))
      (overlay-put ov 'face 'highlight)
      (overlay-put ov 'aperture t))))

(defun aperture--render (session plist)
  "Render normalized PLIST into SESSION's pane."
  (let ((pane (aperture--session-pane session)))
    (unless (window-live-p pane)
      (aperture--log "render dropped: pane window is dead"))
    (when (window-live-p pane)
      (if-let* ((buf (plist-get plist :buffer)))
          ;; A buffer we did not create.  Display it; never kill it.
          (when (buffer-live-p buf) (set-window-buffer pane buf))
        (let ((buf (aperture--content-buffer session)))
          (with-current-buffer buf
            (let ((inhibit-read-only t))
              (erase-buffer)
              (remove-overlays)
              (insert (or (plist-get plist :content) ""))
              (aperture--apply-mode plist)
              (goto-char (point-min))))
          (set-window-buffer pane buf)
          (with-current-buffer buf (aperture--apply-position plist pane))))
      (when-let* ((title (plist-get plist :title)))
        (with-current-buffer (window-buffer pane)
          (setq-local header-line-format title))))))

(defun aperture--render-message (session text)
  "Render TEXT into SESSION's pane as a suppression notice."
  (aperture--render session
                    (list :content (propertize text 'face 'aperture-suppressed))))

;;;; Preview lifecycle

(defun aperture--cancel (session)
  "Cancel any pending or in-flight preview for SESSION."
  (when-let* ((timer (aperture--session-timer session)))
    (cancel-timer timer)
    (setf (aperture--session-timer session) nil))
  (when-let* ((cancel (aperture--session-cancel session)))
    (ignore-errors (funcall cancel))
    (setf (aperture--session-cancel session) nil)))

(defun aperture--fresh-p (session generation)
  "Non-nil if GENERATION is still the current request for SESSION."
  (and (aperture--session-p session)
       (= generation (aperture--session-generation session))))

(defun aperture--log-stale (session generation where)
  "Log that GENERATION was superseded in SESSION at WHERE."
  (aperture--log "drop   gen=%d superseded %s (current %s)" generation where
                 (and (aperture--session-p session)
                      (aperture--session-generation session))))

(defun aperture--deliver (session generation result)
  "Render RESULT for SESSION if GENERATION is still current."
  (if (not (aperture--fresh-p session generation))
      (aperture--log-stale session generation "at deliver")
    (let ((plist (aperture--normalize result)))
      (cond
       ((null plist)
        (aperture--log "render gen=%d no preview" generation)
        (aperture--render-message session "No preview"))
       ((plist-get plist :async)
        (aperture--log "async  gen=%d dispatched" generation)
        (setf (aperture--session-cancel session) (plist-get plist :cancel))
        (funcall (plist-get plist :async)
                 (lambda (res) (aperture--deliver session generation res))))
       (t
        (aperture--log "render gen=%d %s" generation (aperture--log-result plist))
        (aperture--render session plist))))))

(defun aperture--preview (session cand generation)
  "Run SESSION's previewer on CAND, honouring GENERATION."
  (if (not (aperture--fresh-p session generation))
      (aperture--log-stale session generation "before run")
    (let ((fn (aperture--session-previewer session)))
      (aperture--log "run    gen=%d %s" generation fn)
      (condition-case err
          (aperture--deliver session generation
                             (aperture--with-guards (funcall fn cand)))
        (error
         (aperture--log "error  gen=%d %s" generation (error-message-string err))
         (aperture--render-message
          session (format "Preview failed: %s" (error-message-string err))))))))

(defun aperture--schedule (session cand)
  "Schedule a preview of CAND for SESSION, debounced by cost."
  (aperture--cancel session)
  (cl-incf (aperture--session-generation session))
  (let* ((gen (aperture--session-generation session))
         (fn (aperture--session-previewer session))
         (delay (aperture--delay-for fn)))
    (aperture--log "sched  gen=%d delay=%s cost=%s cand=%s"
                   gen delay (aperture--cost fn) (aperture--log-abbrev cand))
    (if (<= delay 0)
        (aperture--preview session cand gen)
      (setf (aperture--session-timer session)
            (run-with-idle-timer delay nil #'aperture--preview session cand gen)))))

;;;; Layout

(defun aperture--size (spec total)
  "Resolve SPEC (integer or fraction) against TOTAL."
  (if (floatp spec) (round (* total spec)) spec))

(defun aperture--projected-pane-width (win)
  "Columns the pane would get from splitting WIN, computed before splitting.
`split-window' with a positive SIZE sizes the window being split, and
that window is the pane -- so this is `aperture-width' resolved against
WIN, not against the frame."
  (aperture--size aperture-width (window-width win)))

(defun aperture--expand-p (win)
  "Non-nil if the session should take the frame rather than split WIN.
See `aperture-min-pane-width'.

Two conditions: the pane must be too narrow, *and* deleting WIN\='s
side-by-side siblings must be capable of widening it.  Windows stacked
above or below WIN are already full width, so they do not count.

`window-total-width\=' rather than `window-width\=': the frame root is an
internal window whenever the frame is split, and `window-width\=' accepts
only live windows.  The comparison also subsumes the sole-window case."
  (and aperture-min-pane-width
       (< (aperture--projected-pane-width win) aperture-min-pane-width)
       (< (window-total-width win)
          (window-total-width (frame-root-window win)))
       t))

(defun aperture--child-frame-capable-p ()
  "Non-nil if this Emacs can draw a child frame here."
  (and (not noninteractive)
       (or (display-graphic-p)
           (featurep 'tty-child-frames))
       t))

(defun aperture--display-mode ()
  "Resolve `aperture-display' against what this display can actually do.
Returns `window'\=' or `child-frame'\='.  A downgrade is logged."
  (if (eq aperture-display 'child-frame)
      (if (aperture--child-frame-capable-p)
          'child-frame
        (aperture--log "layout `child-frame' unavailable (no graphic display), using `window'")
        'window)
    'window))

(defun aperture--build-layout (session)
  "Build the aperture layout for SESSION, per `aperture-display'."
  (if (eq (aperture--display-mode) 'child-frame)
      (progn
        (require 'aperture-child-frame)
        (aperture-child-frame--build session))
    (aperture--build-window-layout session)))

(defun aperture--build-window-layout (session)
  "Split the original window into the aperture layout for SESSION.

Ordering is load-bearing: `minibuffer-selected-window' must end up as the
pane, so consult previews into it.  Splitting `above' leaves it as the
bottom strip; splitting toward `aperture-side' leaves it on the pane
side."
  (let ((orig (minibuffer-selected-window)))
    (if (not (window-live-p orig))
        (aperture--log "layout aborted: no live `minibuffer-selected-window'")
      (setf (aperture--session-pane session) orig
            (aperture--session-pane-buffer session) (window-buffer orig)
            (aperture--session-config session) (current-window-configuration))
      (condition-case err
          (let* ((_ (when (aperture--expand-p orig)
                      ;; Strictly after saving the configuration above: that
                      ;; is the only thing that can put these windows back.
                      (aperture--log
                       "layout taking frame: pane would be %d cols, `aperture-min-pane-width' %d"
                       (aperture--projected-pane-width orig) aperture-min-pane-width)
                      ;; `delete-other-windows' SELECTS the window it keeps,
                      ;; which would take the selection off the minibuffer.
                      (save-selected-window (delete-other-windows orig))
                      (setf (aperture--session-expanded session) t)))
                 (total (window-height orig))
                 (want (aperture--size aperture-height total)))
            (if (>= (- total want) aperture-min-top-height)
                (setf (aperture--session-top-win session)
                      (split-window orig want 'above))
              (aperture--log
               "layout top split skipped: %d lines available, want %d, `aperture-min-top-height' %d"
               total want aperture-min-top-height))
            (setf (aperture--session-list-win session)
                  (split-window orig
                                (aperture--size aperture-width (window-width orig))
                                (if (eq aperture-side 'right) 'left 'right)))
            (aperture--log "layout pane=%s | list=%s | top=%s"
                           (aperture--log-window (aperture--session-pane session))
                           (aperture--log-window (aperture--session-list-win session))
                           (aperture--log-window (aperture--session-top-win session)))
            t)
        (error
         (aperture--log "layout failed: %S" err)
         (message "aperture: layout failed, disabling for this session: %S" err)
         (aperture--restore session)
         nil)))))

(defun aperture--hide-parent-minibuffer (session win)
  "Hide WIN's buffer in WIN while SESSION displays it in a child frame."
  (with-current-buffer (window-buffer win)
    ;; Input is inserted at `point-max'.  Pass REAR-ADVANCE to
    ;; `make-overlay' itself so its rear endpoint follows every keypress.
    (let ((overlay (make-overlay (point-min) (point-max) nil nil t)))
      (overlay-put overlay 'window win)
      (overlay-put overlay 'display "")
      (setf (aperture--session-minibuffer-overlay session) overlay))))

(defun aperture--collapse-parent-minibuffer (session)
  "Hide the parent miniwindow while SESSION displays it in a child frame.

Normally `vertico-buffer--redisplay' performs this when its candidate
overlay is initialized.  Some Emacs builds lose that overlay while a child
frame is made, leaving the same minibuffer buffer visible twice.  The child
frame already shows the buffer, so collapse only its parent miniwindow.
Returns non-nil when the resize was requested."
  (when (aperture--session-frame session)
    (when-let* ((win (active-minibuffer-window))
                ((window-live-p win)))
      (let ((before (window-pixel-height win)))
        (condition-case err
            (progn
              (window-resize win (- before) nil nil 'pixelwise)
              ;; This build clamps the miniwindow at one line (14px).  A
              ;; window-specific display overlay then hides that residual
              ;; line without affecting the same buffer in the child frame.
              (set-window-vscroll win before)
              (aperture--hide-parent-minibuffer session win)
              (aperture--log "minibuf collapse %dpx -> %dpx, vscroll=%d" before
                             (window-pixel-height win) before)
              t)
          (error
           (aperture--log "minibuf collapse failed at %dpx: %S" before err)
           nil))))))

(defun aperture--restore-config (session)
  "Restore SESSION's saved window configuration, if it has one."
  (when-let* ((config (aperture--session-config session)))
    (ignore-errors (set-window-configuration config))))

(defun aperture--restore (session)
  "Undo SESSION's layout.  Three cases:

  - A child-frame session: delete the frame, which is all it touched.
  - A session that took the frame: restore the saved configuration, since
    surgery cannot bring back deleted windows.
  - Otherwise: delete only the windows we created and put the pane's
    buffer back, falling back to the saved configuration."
  (cond
   ((aperture--session-frame session)
    (aperture--log "restore deleting child frame")
    (when-let* ((overlay (aperture--session-minibuffer-overlay session)))
      (delete-overlay overlay))
    (let ((frame (aperture--session-frame session)))
      (when (frame-live-p frame) (ignore-errors (delete-frame frame)))))
   ((aperture--session-expanded session)
    (aperture--restore-config session))
   (t
    (condition-case nil
        (progn
          (dolist (win (list (aperture--session-list-win session)
                             (aperture--session-top-win session)))
            (when (and (window-live-p win) (window-parent win))
              (delete-window win)))
          (when (and (window-live-p (aperture--session-pane session))
                     (buffer-live-p (aperture--session-pane-buffer session)))
            (set-window-buffer (aperture--session-pane session)
                               (aperture--session-pane-buffer session))))
      (error (aperture--restore-config session))))))

;;;; Session driver

(defun aperture--consult-owns-p ()
  "Non-nil if consult has installed its own preview in this minibuffer.
`consult--preview-function' is set exactly when consult owns preview;
consult itself tests it this way."
  (and (bound-and-true-p consult--preview-function) t))

(defun aperture--skip-reason (category command)
  "Explain why no pane should open for CATEGORY and COMMAND, or return nil.
A reason rather than a boolean, so the log can name it."
  (cond
   ((null aperture-key) "`aperture-key' is nil")
   ((null aperture-frontend) "no frontend installed")
   ((not (or (aperture--previewer-for category command)
             (memq category aperture-consult-categories)))
    (if category
        (format "no previewer for category `%s'" category)
      "no completion category"))))

(defun aperture--should-activate-p (category command)
  "Non-nil if aperture should open a pane for CATEGORY and COMMAND."
  (null (aperture--skip-reason category command)))

(defun aperture--install-keys ()
  "Bind aperture's minibuffer keys for this session.
Uses `minor-mode-overriding-map-alist', keyed on `aperture--session', so
the bindings live exactly as long as the session and vertico's own local
map cannot clobber them."
  (let ((map (make-sparse-keymap))
        (keys (car (aperture--key-normalize aperture-key))))
    (keymap-set map "C-M-v" #'aperture-scroll-up)
    (keymap-set map "C-M-S-v" #'aperture-scroll-down)
    ;; On-demand mode: the configured keys request a preview.
    (when (consp keys)
      (dolist (key keys)
        (ignore-errors (keymap-set map key #'aperture-preview-now))))
    (setq-local minor-mode-overriding-map-alist
                (cons (cons 'aperture--session map)
                      minor-mode-overriding-map-alist))))

(defun aperture--setup (&rest _)
  "Open a session if this minibuffer warrants one.
Must run after `minibuffer-completion-table' is set and before
vertico-buffer picks a window; the frontend installs it as `:before'
advice on `vertico--setup', which sits between the two."
  ;; Before the skip check, so the adapter is installed even for sessions
  ;; aperture itself declines.
  (aperture--consult-arrange)
  (let* ((category (aperture--category))
         (command this-command)
         (reason (aperture--skip-reason category command)))
    (if reason
        (aperture--log "setup  cmd=%s cat=%s -- no session: %s"
                       command category reason)
      (let* ((session (aperture--session-make
                       :previewer (aperture--previewer-for category command)))
             ;; A child-frame `make-frame' may change `current-buffer' on
             ;; some Emacs builds.  Session state, keys and hooks belong to
             ;; the buffer owning this minibuffer, regardless of that side
             ;; effect.
             (minibuffer-buffer
              (or (when-let* ((win (active-minibuffer-window))
                              (buf (window-buffer win)))
                    buf)
                  (current-buffer))))
        (aperture--log "setup  cmd=%s cat=%s previewer=%s"
                       command category
                       (or (aperture--session-previewer session)
                           "none (consult category)"))
        (when (aperture--build-layout session)
          ;; `make-frame' may have switched `current-buffer'; leave the
          ;; following Vertico methods in the active minibuffer's context.
          ;; `set-buffer' preserves the selected minibuffer window.
          (set-buffer minibuffer-buffer)
          (setq aperture--session session)
          (aperture--install-keys)
          (add-hook 'post-command-hook #'aperture--post-command nil t))))))

(defun aperture--teardown ()
  "Close the session for this minibuffer."
  (when-let* ((session aperture--session))
    (aperture--log "teardown after %d preview request(s)"
                   (aperture--session-generation session))
    (aperture--cancel session)
    (aperture--restore session)
    (dolist (buf (aperture--session-buffers session))
      (when (buffer-live-p buf) (kill-buffer buf)))
    (setq aperture--session nil)))

(defun aperture--post-command ()
  "Detect a selection change and schedule a preview."
  (when-let* ((session aperture--session)
              ((aperture--frontend :active-p)))
    ;; consult drives its own preview from its own post-command hook; stand
    ;; down rather than render into the same window.
    (let ((owned (aperture--consult-owns-p)))
      (unless (eq owned (aperture--session-consult-owned session))
        (aperture--log "consult %s preview" (if owned "took" "released")))
      (setf (aperture--session-consult-owned session) owned))
    (unless (or (aperture--session-consult-owned session)
                (null (aperture--session-previewer session))
                (not (aperture--live-p)))
      (let ((key (cons (aperture--frontend :index)
                       (buffer-substring-no-properties
                        (minibuffer-prompt-end) (point-max)))))
        (unless (equal key (aperture--session-last-key session))
          (setf (aperture--session-last-key session) key)
          (when-let* ((cand (aperture--frontend :candidate)))
            (aperture--schedule session cand)))))))

;;;; Commands

(defun aperture-preview-now ()
  "Render a preview for the current candidate immediately."
  (interactive)
  (when-let* ((session aperture--session)
              (cand (aperture--frontend :candidate)))
    (cl-incf (aperture--session-generation session))
    (aperture--preview session cand (aperture--session-generation session))))

(defun aperture--scroll (lines)
  "Scroll the pane by LINES without selecting it."
  (when-let* ((session aperture--session)
              (win (aperture--session-pane session))
              ((window-live-p win)))
    (with-selected-window win
      (condition-case nil (scroll-up lines) (error nil)))))

(defun aperture-scroll-up ()
  "Scroll the preview pane down a screenful."
  (interactive)
  (aperture--scroll nil))

(defun aperture-scroll-down ()
  "Scroll the preview pane up a screenful."
  (interactive)
  (aperture--scroll '-))

;;;; Mode

(defun aperture--consult-arrange ()
  "Install the consult adapter if consult has been loaded.
Polled from `aperture--setup' rather than hung off `with-eval-after-load',
whose entries would outlive `aperture-mode'.  Calling this repeatedly is
free: `require' on a loaded feature is a no-op, and `advice-add' will not
add the same advice twice."
  (when (featurep 'consult)
    (require 'aperture-consult)
    (aperture-consult-install)))

;;;###autoload
(define-minor-mode aperture-mode
  "Show a rich preview pane beside completion candidates."
  :global t
  (if aperture-mode
      (progn
        (require 'aperture-previewers)
        (require 'aperture-vertico)
        (aperture--log "--- aperture-mode enabled (emacs %s) ---" emacs-version)
        ;; Session start is installed by the frontend; see
        ;; `aperture-vertico-install'.
        (aperture-vertico-install)
        (aperture--consult-arrange)
        ;; Late, so vertico-buffer restores its own state and consult resets
        ;; its preview -- both while the pane still exists -- before we take
        ;; the layout down.
        (add-hook 'minibuffer-exit-hook #'aperture--teardown 90))
    (remove-hook 'minibuffer-exit-hook #'aperture--teardown)
    (when (fboundp 'aperture-vertico-uninstall)
      (aperture-vertico-uninstall))
    (when (featurep 'aperture-consult)
      (aperture-consult-uninstall))))

(provide 'aperture)
;;; aperture.el ends here
