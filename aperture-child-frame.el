;;; aperture-child-frame.el --- Child-frame layout for aperture -*- lexical-binding: t -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; The opt-in layout, reached through `aperture-display': the whole aperture UI
;; -- prompt, candidate list and preview pane -- floats in a child frame over
;; the parent, leaving every one of the user's windows visible behind it.
;;
;;     +---------------------------------------+
;;     |  your windows, untouched              |
;;     |     +---------------+-------------+   |
;;     |     | prompt+input  |  preview    |   |
;;     |     | candidates    |  pane       |   |
;;     |     +---------------+-------------+   |
;;     +---------------------------------------+
;;
;; Two facts carry the design.  Both are confirmed on hardware by
;; dev/spike-posframe.el; the reasoning is in docs/DESIGN.md section 3.4b.
;;
;; 1. The frame borrows the parent's minibuffer window.  Selecting a window
;;    here selects the frame -- which is how consult's preview reaches the pane
;;    -- and `minibuffer-follows-selected-frame' would otherwise relocate the
;;    active minibuffer onto it.  With no minibuffer to receive one, it cannot.
;;
;; 2. The pane cannot be `minibuffer-selected-window', so the invariant the
;;    `window' layout relies on is unavailable, and `aperture-consult.el'
;;    redirects `consult--original-window' instead.
;;
;; This is not vertico-posframe integration; aperture owns this frame.  See
;; `aperture-vertico.el' for how it stands down for that package.

;;; Code:

(require 'aperture)

;;;; Customization

(defcustom aperture-child-frame-width 0.8
  "Width of the aperture child frame.
A float is a fraction of the parent frame's width; an integer is columns."
  :type '(choice float integer)
  :group 'aperture)

(defcustom aperture-child-frame-height 0.6
  "Height of the aperture child frame.
A float is a fraction of the parent frame's height; an integer is lines."
  :type '(choice float integer)
  :group 'aperture)

(defcustom aperture-child-frame-position 'center
  "Where the child frame sits over the parent.

`center'\\=' centres it.  `top'\\=' centres it horizontally and places it a
short way down from the top, which keeps more of the parent visible
below.  A cons cell (X . Y) is an explicit pixel offset from the parent's
top-left.  A function is called with the parent frame and the frame\\='s
pixel width and height, and must return such a cons."
  :type '(choice (const :tag "Centred" center)
                 (const :tag "Near the top" top)
                 (cons :tag "Pixel offset" integer integer)
                 (function :tag "Function of (parent width height)"))
  :group 'aperture)

(defcustom aperture-child-frame-border-width 1
  "Border width, in pixels, of the aperture child frame.
Zero for no border."
  :type 'natnum
  :group 'aperture)

(defcustom aperture-child-frame-parameters nil
  "Extra frame parameters for the aperture child frame.
Appended last, so anything here overrides aperture's own choices.  Use it
for fonts, fringes, `alpha' and the like."
  :type '(alist :key-type symbol :value-type sexp)
  :group 'aperture)

;;;; Geometry

(defun aperture-child-frame--geometry (parent)
  "Return (X Y WIDTH HEIGHT) in pixels for a child frame over PARENT.

Kept separate from frame creation because it is the only part of this
file batch can reach; everything else needs a display."
  (let* ((pw (frame-pixel-width parent))
         (ph (frame-pixel-height parent))
         (cw (frame-char-width parent))
         (ch (frame-char-height parent))
         (w (if (floatp aperture-child-frame-width)
                (round (* pw aperture-child-frame-width))
              (* aperture-child-frame-width cw)))
         (h (if (floatp aperture-child-frame-height)
                (round (* ph aperture-child-frame-height))
              (* aperture-child-frame-height ch))))
    ;; `aperture-min-pane-width' means the same thing in both layouts.  Here it
    ;; widens the frame rather than taking the parent's windows (section 3.4a).
    (when aperture-min-pane-width
      (let* ((share (if (floatp aperture-width) aperture-width 0.5))
             (needed (round (/ (* aperture-min-pane-width cw) (max share 0.1)))))
        (setq w (min pw (max w needed)))))
    (setq w (min w pw) h (min h ph))
    (pcase-let ((`(,x . ,y)
                 (pcase aperture-child-frame-position
                   ('center (cons (/ (- pw w) 2) (/ (- ph h) 2)))
                   ('top (cons (/ (- pw w) 2) (min (/ (- ph h) 2) (* 2 ch))))
                   ((and (pred functionp) fn) (funcall fn parent w h))
                   ((and (pred consp) pos) pos)
                   (_ (cons (/ (- pw w) 2) (/ (- ph h) 2))))))
      (list (max 0 x) (max 0 y) w h))))

;;;; The frame

(defun aperture-child-frame--make (parent)
  "Create and show the aperture child frame over PARENT."
  (pcase-let* ((`(,x ,y ,w ,h) (aperture-child-frame--geometry parent))
               (frame-resize-pixelwise t)
               (frame
                (make-frame
                 (append
                  aperture-child-frame-parameters
                  `((parent-frame . ,parent)
                    ;; Load-bearing; see the Commentary.
                    (minibuffer . ,(minibuffer-window parent))
                    (undecorated . t)
                    (no-accept-focus . t)
                    (no-focus-on-map . t)
                    (no-other-frame . t)
                    (desktop-dont-save . t)
                    (unsplittable . nil)
                    (internal-border-width . ,aperture-child-frame-border-width)
                    (child-frame-border-width . ,aperture-child-frame-border-width)
                    (vertical-scroll-bars . nil)
                    (horizontal-scroll-bars . nil)
                    (menu-bar-lines . 0)
                    (tool-bar-lines . 0)
                    (tab-bar-lines . 0)
                    ;; Created hidden and shown once it is sized and placed, so
                    ;; the frame never appears at the wrong size first.
                    (visibility . nil))))))
    (set-frame-size frame w h t)
    (set-frame-position frame x y)
    (make-frame-visible frame)
    (aperture--log "frame  %dx%d px at (%d,%d) over %dx%d"
                   w h x y (frame-pixel-width parent) (frame-pixel-height parent))
    frame))

(defun aperture-child-frame--build (session)
  "Build the child-frame layout for SESSION.  Return non-nil on success.

Same contract as `aperture--build-window-layout': fill the session's
window slots, or log and return nil so the caller declines the session.
There is no split ordering to get right here and no window configuration
to save, because the parent frame is never touched."
  (let ((parent (window-frame (minibuffer-window))))
    (condition-case err
        (let* ((frame (aperture-child-frame--make parent))
               (root (frame-root-window frame))
               (pane-first (eq aperture-side 'left))
               (split (aperture--size aperture-width (window-width root)))
               ;; `split-window' SIZE sizes the window being split, and
               ;; splitting `right' leaves ROOT on the left.  So SIZE is the
               ;; pane's share when the pane is ROOT, and the list's otherwise.
               (other (split-window root
                                    (if pane-first split (- (window-width root) split))
                                    'right)))
          (setf (aperture--session-frame session) frame
                (aperture--session-top-win session) nil
                (aperture--session-config session) nil
                (aperture--session-pane session) (if pane-first root other)
                (aperture--session-list-win session) (if pane-first other root))
          (let ((pane (aperture--session-pane session)))
            ;; `pane-buffer' stays nil: it exists so the window layout can put
            ;; a borrowed window's buffer back, and this layout borrows nothing.
            (set-window-buffer pane (aperture--content-buffer session))
            ;; Nothing in the parent frame should walk in here with
            ;; `other-window'.
            (dolist (win (list pane (aperture--session-list-win session)))
              (set-window-parameter win 'no-other-window t)))
          (aperture--log "layout child-frame pane=%s | list=%s"
                         (aperture--log-window (aperture--session-pane session))
                         (aperture--log-window (aperture--session-list-win session)))
          t)
      (error
       (aperture--log "layout child frame failed: %S" err)
       (message "aperture: child frame failed, disabling for this session: %S" err)
       (aperture--restore session)
       nil))))

(provide 'aperture-child-frame)
;;; aperture-child-frame.el ends here
