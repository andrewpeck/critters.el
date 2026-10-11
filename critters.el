;;; critters.el --- Critters that hop around your buffer  -*- lexical-binding: t; -*-

;; Author: Andrew Peck <me@andrewpeck.xyz>
;; Version: 0.1
;; Package-Requires: ((emacs "32.0"))
;; Keywords: games

;;; Commentary:

;; Proof of concept for the Emacs 32 canvas image API.
;;
;; Small pixel art critters are drawn into canvas images which live in
;; child frames floating over the selected window.  The critters treat
;; the top edges of text as platforms: they walk along them, turn
;; around at their ends, and jump / flap up to reach other ones.
;;
;; M-x critters-mode to toggle.  `critters-flock' sets which critters
;; and how many.

;;; Code:

(require 'cl-lib)

;; Optional dynamic module (see Makefile) that clips each critter's
;; frame to its sprite, removing the background box around it.
(require 'critters-shape
         (expand-file-name "critters-shape"
                           (file-name-directory (macroexp-file-name)))
         t)
(declare-function critters-shape-set "critters-shape" (display window rects))

(defgroup critters nil
  "Critters that hop around your buffer."
  :group 'games)

(defcustom critters-flock
  '((chicken . 1) (rooster . 1) (degu . 2) (skink . 1))
  "Critters to hatch, as an alist of (SPECIES . COUNT).
SPECIES is one of the species in `critters--species'.  Takes
effect when `critters-mode' is enabled."
  :type '(alist :key-type (symbol :tag "Species")
                :value-type (natnum :tag "Count")))

(defcustom critters-style 'frames
  "Where the critters live.
`frames' means over the text of the selected window, each in its own
child frame.  `bottom' is the same, but they only walk along the
bottom of the window, just above the mode line, and never jump,
which is less intrusive.  Takes effect when `critters-mode' is
enabled."
  :type '(choice (const :tag "Over the text" frames)
                 (const :tag "Along the bottom of the window" bottom)))

(defcustom critters-shuffle nil
  "Non-nil means only some of the flock is out at a time, taking turns.
`critters-shuffle-count' critters are out at once, and every
`critters-shuffle-interval' seconds the one that has been out the
longest makes way for the next in `critters-flock'.  This keeps the
variety while computing fewer critters.  Takes effect when
`critters-mode' is enabled."
  :type 'boolean)

(defcustom critters-shuffle-count 2
  "Number of critters out at once with `critters-shuffle'."
  :type 'natnum)

(defcustom critters-shuffle-interval 30
  "Seconds between turns with `critters-shuffle'.
Only time spent animating counts, not time spent typing."
  :type 'number)

(defcustom critters-scale 2
  "Size in screen pixels of one sprite pixel."
  :type 'natnum)

(defcustom critters-fps 30
  "Animation frames per second."
  :type 'natnum)

(defcustom critters-idle-delay 0.01
  "Seconds of idle time before the critters start moving.
They freeze as soon as you run a command."
  :type 'number)

(defcustom critters-roost-delay 300
  "Seconds of idle time after which the critters settle down to sleep.
They wake up the next time Emacs is idle after some input.  nil
means they never roost."
  :type '(choice (number :tag "Seconds") (const :tag "Never" nil)))

(defcustom critters-pause-when-unfocused t
  "Non-nil means the critters pause while their frame isn't focused.
They always pause while it is minimized or hidden."
  :type 'boolean)

(defcustom critters-breeds
  '((chicken
     (black (?W . #xFF262626) (?G . #xFF3D4F44) (?K . #xFFE6E6E6)
            (?B . #xFF262626) (?Y . #xFF5A5A5A)
            (outline . #xFF9A9A9A))
     (white)
     (brown (?W . #xFFA0602F) (?G . #xFF6E3B1A))
     (buff (?W . #xFFE9BE73) (?G . #xFFC99442)))
    (rooster (junior))
    (degu (agouti))
    (skink (blue-tongue)))
  "Breeds of each species, as (SPECIES (NAME . OVERRIDES)...).
OVERRIDES map characters of the species' sprite frames to ARGB
colors, and `outline' to the outline color.  See the palettes in
`critters--species' for what each character is.  Critters of a
species are hatched with its breeds in order, starting over when
the list runs out."
  :type 'sexp)

;;;; Species

(defconst critters--chicken-frames
  '((stand
     "......RR...."
     ".....RRR...."
     ".....WWWW..."
     ".....WWKWBB."
     ".....WWWWR.."
     ".W...WWWW..."
     ".WW.WWWWW..."
     ".WWWWWWWWW.."
     ".WWWGGGWWW.."
     "..WWWGGWWW.."
     "...WWWWWW..."
     "....Y..Y....")
    (walk
     "......RR...."
     ".....RRR...."
     ".....WWWW..."
     ".....WWKWBB."
     ".....WWWWR.."
     ".W...WWWW..."
     ".WW.WWWWW..."
     ".WWWWWWWWW.."
     ".WWWGGGWWW.."
     "..WWWGGWWW.."
     "...WWWWWW..."
     "...Y....Y...")
    (blink
     "......RR...."
     ".....RRR...."
     ".....WWWW..."
     ".....WWWWBB."
     ".....WWWWR.."
     ".W...WWWW..."
     ".WW.WWWWW..."
     ".WWWWWWWWW.."
     ".WWWGGGWWW.."
     "..WWWGGWWW.."
     "...WWWWWW..."
     "....Y..Y....")
    (flap-up
     "......RR...."
     ".....RRR...."
     "..G..WWWW..."
     ".GGG.WWKWBB."
     ".GGGGWWWWR.."
     ".WGGGWWWW..."
     ".WWGGWWWW..."
     ".WWWWWWWWW.."
     ".WWWWWWWWW.."
     "..WWWWWWWW.."
     "...WWWWWW..."
     ".....YY.....")
    (flap-down
     "......RR...."
     ".....RRR...."
     ".....WWWW..."
     ".....WWKWBB."
     ".....WWWWR.."
     ".W...WWWW..."
     ".WW.WWWWW..."
     ".WWWWWWWWW.."
     ".WWWWWWWWW.."
     "..WWGGGWWW.."
     "...GGGGWW..."
     "...GGYY.....")))

(defconst critters--rooster-frames
  '((stand
     ".......RRR..."
     "......RRRR..."
     "......NNNN..."
     "......NNKNBB."
     "......NNNNR.."
     ".TL...NNNNR.."
     "TDGL.NNNNN..."
     "T.TLGGMGMN..."
     "..LGMGMGML..."
     "..TWLGMGLL..."
     "...LWGMLWG..."
     "....LLGWL...."
     ".....Y..Y....")
    (walk
     ".......RRR..."
     "......RRRR..."
     "......NNNN..."
     "......NNKNBB."
     "......NNNNR.."
     ".TL...NNNNR.."
     "TDGL.NNNNN..."
     "T.TLGGMGMN..."
     "..LGMGMGML..."
     "..TWLGMGLL..."
     "...LWGMLWG..."
     "....LLGWL...."
     "....Y....Y...")
    (blink
     ".......RRR..."
     "......RRRR..."
     "......NNNN..."
     "......NNNNBB."
     "......NNNNR.."
     ".TL...NNNNR.."
     "TDGL.NNNNN..."
     "T.TLGGMGMN..."
     "..LGMGMGML..."
     "..TWLGMGLL..."
     "...LWGMLWG..."
     "....LLGWL...."
     ".....Y..Y....")
    (crow
     ".......RRR..."
     "......RRRR..."
     "......NNNN.B."
     "......NNKN..."
     "......NNNNB.."
     ".TL...NNNNR.."
     "TDGL.NNNNNR.."
     "T.TLGGMGMN..."
     "..LGMGMGML..."
     "..TWLGMGLL..."
     "...LWGMLWG..."
     "....LLGWL...."
     ".....Y..Y....")
    (flap-up
     ".......RRR..."
     "......RRRR..."
     "...M..NNNN..."
     "..GMG.NNKNBB."
     "..MGMGNNNNR.."
     ".TGMGMNNNNR.."
     "TDGMGNNNNN..."
     "T.TLGGMGNW..."
     "..LGMGMWWL..."
     "..TWLWWWLL..."
     "...LWGWLWG..."
     "....LLGWL...."
     "......YY.....")
    (flap-down
     ".......RRR..."
     "......RRRR..."
     "......NNNN..."
     "......NNKNBB."
     "......NNNNR.."
     ".TL...NNNNR.."
     "TDGL.NNNNN..."
     "T.TLGGMGMN..."
     "..LGMGMGML..."
     "..TWLWWWLL..."
     "...LGMGMWG..."
     "...MGMGWL...."
     "...GMY.Y.....")))

(defconst critters--degu-frames
  '((stand
     "..................DD...."
     ".................DEED..."
     "...........BBBBB.DEED..."
     ".........BBBBBBBBBDDD..."
     "........BBBBBBBBBBBBBB.."
     "........BBBBBBBBBBBBBBB."
     ".TT.....BBBBBBBBBBBBBKBB"
     "TTTBBBBBBBBBBBBBBBBBBBBD"
     ".TT......BBBBBBBBBCBBBB."
     "..........FFF...FF......")
    (walk
     "..................DD...."
     ".................DEED..."
     "...........BBBBB.DEED..."
     ".........BBBBBBBBBDDD..."
     "........BBBBBBBBBBBBBB.."
     "........BBBBBBBBBBBBBBB."
     ".TT.....BBBBBBBBBBBBBKBB"
     "TTTBBBBBBBBBBBBBBBBBBBBD"
     ".TT......BBBBBBBBBCBBBB."
     ".........FF..F..F..F....")
    (blink
     "..................DD...."
     ".................DEED..."
     "...........BBBBB.DEED..."
     ".........BBBBBBBBBDDD..."
     "........BBBBBBBBBBBBBB.."
     "........BBBBBBBBBBBBBBB."
     ".TT.....BBBBBBBBBBBBBBBB"
     "TTTBBBBBBBBBBBBBBBBBBBBD"
     ".TT......BBBBBBBBBCBBBB."
     "..........FFF...FF......")
    (sit
     "..............DD........"
     ".............DEEDBB....."
     ".............DEEDBBB...."
     "............BBDDBBKBB..."
     "............BBBBBBBBBD.."
     "...........BBBBBBBCFF..."
     "..........BBBBBBBBC....."
     ".TT......BBBBBBBBBC....."
     "TTTBBBBBBBBBBBBBBBC....."
     ".TT......BFFFBBBFF......")
    (hop
     "..................DD...."
     ".................DEED..."
     "...........BBBBB.DEED..."
     ".TT......BBBBBBBBBDDD..."
     "TTTBBBBBBBBBBBBBBBBBBB.."
     ".TT.....BBBBBBBBBBBBBBB."
     "........BBBBBBBBBBBBBKBB"
     ".........BBBBBBBBBBBBBBD"
     ".........FFF......FF...."
     "........................")))

(defconst critters--skink-frames
  '((stand
     "............................"
     "..........XXSSXXSSXXS.HHH..."
     "....SSXXSSXXSSXXSSXXSHHKHH.."
     "SSXXSSXXSSXXSSXXSSXXSHHHHHH."
     "....SSXXSSXXSSXXSSXXSSHHH..."
     "..........XX......XX........")
    (walk
     "............................"
     "..........XXSSXXSSXXS.HHH..."
     "....SSXXSSXXSSXXSSXXSHHKHH.."
     "SSXXSSXXSSXXSSXXSSXXSHHHHHH."
     "....SSXXSSXXSSXXSSXXSSHHH..."
     ".........XX........XX.......")
    (blink
     "............................"
     "..........XXSSXXSSXXS.HHH..."
     "....SSXXSSXXSSXXSSXXSHHHHH.."
     "SSXXSSXXSSXXSSXXSSXXSHHHHHH."
     "....SSXXSSXXSSXXSSXXSSHHH..."
     "..........XX......XX........")
    (tongue
     "............................"
     "..........XXSSXXSSXXS.HHH..."
     "....SSXXSSXXSSXXSSXXSHHKHH.T"
     "SSXXSSXXSSXXSSXXSSXXSHHHHHHT"
     "....SSXXSSXXSSXXSSXXSSHHH..T"
     "..........XX......XX........")))

(defconst critters--species
  `((chicken
     :frames ,critters--chicken-frames
     :palette ((?W . #xFFFFFFFF)        ; Body.
               (?G . #xFFB4B4B4)        ; Wing.
               (?R . #xFFE0302A)        ; Comb and wattle.
               (?B . #xFFF2B233)        ; Beak.
               (?Y . #xFFF2B233)        ; Legs.
               (?K . #xFF000000))       ; Eye.
     :fly t :jump 5 :walk (0.8 . 1.7) :walk-ticks (20 . 80) :step-ticks 4
     :edge-turn 85
     :actions ((idle . 4) (walk . 3) (jump . 3)))
    (rooster
     :frames ,critters--rooster-frames
     :palette ((?W . #xFFF1EBDD)        ; Body.
               (?N . #xFFE8D3A0)        ; Neck.
               (?T . #xFFF6F2E8)        ; Tail.
               (?D . #xFF4A3A2A)        ; Tail streak.
               (?G . #xFFA8672E)        ; Wing and back, light mottle.
               (?M . #xFF6E3F1C)        ; Wing and back, dark mottle.
               (?L . #xFFD8BC8C)        ; Tan flecks.
               (?R . #xFFE0302A)        ; Comb and wattle.
               (?B . #xFFE5CFA0)        ; Beak.
               (?Y . #xFFE0A890)        ; Legs.
               (?K . #xFF000000))       ; Eye.
     :fly t :jump 5 :walk (0.8 . 1.7) :walk-ticks (20 . 80) :step-ticks 4
     :edge-turn 85
     :actions ((idle . 4) (walk . 3) (jump . 2) (crow . 1))
     :poses ((crow crow 20 . 40)))
    (degu
     :frames ,critters--degu-frames
     :palette ((?B . #xFF8B6A47)        ; Body.
               (?D . #xFF4A3626)        ; Ears and nose.
               (?E . #xFFA8846A)        ; Inner ears.
               (?T . #xFF4A3626)        ; Tail.
               (?C . #xFFBFA078)        ; Belly.
               (?F . #xFFC9A27E)        ; Feet.
               (?K . #xFF111111))       ; Eye.
     :jump 4 :walk (2.4 . 3.6) :walk-ticks (15 . 50) :step-ticks 2
     :edge-turn 75
     :actions ((idle . 2) (walk . 4) (jump . 3) (sit . 2))
     :poses ((sit sit 30 . 90)))
    (skink
     :frames ,critters--skink-frames
     :palette ((?S . #xFFB9A68B)        ; Body.
               (?H . #xFFD2C5AE)        ; Head.
               (?X . #xFF5A4632)        ; Bands and legs.
               (?T . #xFF2F5FD8)        ; Tongue.
               (?K . #xFF111111))       ; Eye.
     :walk (0.3 . 0.5) :walk-ticks (60 . 180) :step-ticks 8
     :edge-turn 60
     :actions ((idle . 3) (walk . 3) (tongue . 5) (bask . 2))
     :poses ((tongue tongue 8 . 16) (bask blink 90 . 240))))
  "Species of critter, as (NAME . PLIST).
PLIST has these properties:

 :frames      Alist of sprite frames, facing right, each a list of
              rows of palette characters, `.' being transparent.
              Every species needs `stand', `walk' and `blink'.
              Flying species need `flap-up' and `flap-down', others
              may have `hop'.  All frames must be the same size, and
              the bottom row is where the feet are.
 :palette     Alist mapping characters to ARGB colors.
 :outline     ARGB color of the outline, see `critters--outline'.
 :fly         Non-nil to flap when falling, and fly from the floor
              back up to the nearest text.
 :jump        Lines a jump can reach, or nil to never jump.
 :walk        Range (MIN . MAX) of walking speeds in pixels per tick.
 :walk-ticks  Range (MIN . MAX) of how long a walk lasts.
 :step-ticks  Ticks per step of the walking animation.
 :edge-turn   Percent chance of turning around at the end of text.
 :actions     Alist of (ACTION . WEIGHT): `idle', `walk', `jump', or
              a pose.
 :poses       List of (ACTION FRAME MIN . MAX): standing still showing
              FRAME for MIN to MAX ticks.")

(defconst critters--outline #xFF3A2A1A
  "Default ARGB color of the outline drawn around sprites.")

;;;; Sprites

(defun critters--compile (rows palette outline)
  "Convert ROWS of PALETTE characters into a vector of ARGB pixels.
Transparent pixels are nil.  Transparent pixels next to opaque ones
become OUTLINE."
  (let* ((w (length (car rows)))
         (h (length rows))
         (px (make-vector (* w h) nil))
         (out nil))
    (cl-loop for row in rows for y from 0 do
             (unless (= (length row) w)
               (error "Sprite row %S is not %d wide" row w))
             (cl-loop for c across row for x from 0 do
                      (aset px (+ x (* y w)) (alist-get c palette))))
    (setq out (copy-sequence px))
    (dotimes (y h)
      (dotimes (x w)
        (unless (aref px (+ x (* y w)))
          (when (cl-some (lambda (d)
                           (let ((nx (+ x (car d))) (ny (+ y (cdr d))))
                             (and (< -1 nx w) (< -1 ny h)
                                  (aref px (+ nx (* ny w))))))
                         '((1 . 0) (-1 . 0) (0 . 1) (0 . -1)))
            (aset out (+ x (* y w)) outline)))))
    out))

(defun critters--mirror (pixels w)
  "Return PIXELS of a sprite W pixels wide flipped horizontally."
  (let* ((h (/ (length pixels) w))
         (out (make-vector (* w h) nil)))
    (dotimes (y h)
      (dotimes (x w)
        (aset out (+ (- w 1 x) (* y w)) (aref pixels (+ x (* y w))))))
    out))

(defun critters--canvas-data (pixels w bg)
  "Return the canvas data for PIXELS of a sprite W pixels wide.
Pixels are scaled up by `critters-scale' onto the ARGB color BG."
  (let* ((s critters-scale)
         (sw (* w s))
         (data (make-vector (* sw s (/ (length pixels) w)) bg)))
    (dotimes (i (length pixels))
      (let ((p (aref pixels i)))
        (when p
          (let ((x0 (* s (% i w)))
                (y0 (* s (/ i w))))
            (dotimes (dy s)
              (dotimes (dx s)
                (aset data (+ x0 dx (* (+ y0 dy) sw)) p)))))))
    data))

(defun critters--shape-rects (pixels w)
  "Return a flat vector [X Y W H ...] of the opaque parts of PIXELS.
The sprite is W pixels wide.  The rectangles are in screen pixels,
for `critters-shape-set'."
  (let ((s critters-scale)
        rects)
    (dotimes (y (/ (length pixels) w))
      (let ((x 0))
        (while (< x w)
          (if (not (aref pixels (+ x (* y w))))
              (cl-incf x)
            (let ((x0 x))
              (while (and (< x w) (aref pixels (+ x (* y w))))
                (cl-incf x))
              (push (vector (* x0 s) (* y s) (* (- x x0) s) s) rects))))))
    (apply #'vconcat rects)))

(defun critters--build-sprites (frames palette outline bg)
  "Return an alist mapping the names of FRAMES to (RIGHT . LEFT).
RIGHT and LEFT are the sprite facing each way as (DATA . RECTS) on
background BG, see `critters--canvas-data' and `critters--shape-rects'.
PALETTE and OUTLINE are the colors to use."
  (cl-loop for (name . rows) in frames
           for w = (length (car rows))
           for right = (critters--compile rows palette outline)
           for left = (critters--mirror right w)
           collect (cons name
                         (cons (cons (critters--canvas-data right w bg)
                                     (critters--shape-rects right w))
                               (cons (critters--canvas-data left w bg)
                                     (critters--shape-rects left w))))))

;;;; State

(defconst critters--gravity 0.6
  "Downward acceleration in pixels per tick squared.")

(defconst critters--max-fall 6.0
  "Fall speed in pixels per tick above which flying critters flutter.")

(defconst critters--calm-ticks 6
  "Ticks between updates while every critter is standing still.
This is also how long a blink lasts, so slow updates never miss one.")

(cl-defstruct (critters--pet (:constructor critters--pet-create)
                             (:copier nil))
  "State of one critter.
Positions are in pixels relative to the window's text area.  X is
the horizontal center of the critter and Y is the bottom of its feet."
  kind                                  ; Species plist.
  sprites                               ; From `critters--build-sprites'.
  w h                                   ; Canvas size in screen pixels.
  frame                                 ; Child frame showing the canvas.
  xid                                   ; X window id of the frame.
  image                                 ; The canvas image spec.
  buffer                                ; Buffer displaying the image.
  drawn                                 ; Sprite (DATA . RECTS) shown.
  left top                              ; Child frame position.
  (phase 0)                             ; Animation offset in ticks.
  (x 0.0) (y 0.0) (vx 0.0) (vy 0.0)
  (facing 1)
  (state 'air)                          ; `ground' or `air'.
  (action 'idle)                        ; `idle', `walk' or a pose.
  (action-ticks 0)                      ; Ticks left in the action.
  flapping
  target)                               ; Point (X . Y) jumping to, or nil.

(defun critters--pet-get (pet prop)
  "Return the species property PROP of PET."
  (plist-get (critters--pet-kind pet) prop))

(defvar critters-mode)

(defvar critters--pets nil "List of `critters--pet'.")
(defvar critters--active nil
  "The critters that are out, a subset of `critters--pets'.
With `critters-shuffle' it is in the order they came out.")
(defvar critters--queue nil "The critters waiting for their turn.")
(defvar critters--shuffle-time 0.0 "Seconds of animation since the last turn.")
(defvar critters--parent nil "Frame the critters live in.")
(defvar critters--bg 0 "ARGB background color of the canvases.")
(defvar critters--top 0 "Height in pixels of the tallest critter.")
(defvar critters--timer nil "Animation timer, only running while idle.")
(defvar critters--idle-timer nil "Idle timer that wakes the critters.")
(defvar critters--window nil "Window the critters are currently in.")
(defvar critters--surfaces-key nil)
(defvar critters--surfaces nil)
(defvar critters--pending 1 "Ticks of time the next tick advances by.")
(defvar critters--roosting nil "Non-nil once the critters should settle down.")
(defvar critters--ticks 0)

(defun critters--bottom-p ()
  "Return non-nil if the critters stay on the bottom of the window."
  (eq critters-style 'bottom))

;;;; Surfaces

(defun critters--subtract (runs blockers)
  "Return the parts of RUNS not covered by BLOCKERS.
Both are lists of pixel ranges (X1 . X2)."
  (dolist (b blockers runs)
    (setq runs
          (mapcan (lambda (r)
                    (if (or (<= (cdr b) (car r)) (>= (car b) (cdr r)))
                        (list r)
                      (append (when (< (car r) (car b))
                                (list (cons (car r) (car b))))
                              (when (> (cdr r) (cdr b))
                                (list (cons (cdr b) (cdr r)))))))
                  runs))))

(defun critters--line-runs (beg end x0 cw)
  "Return the pixel ranges (X1 . X2) of non-blank text from BEG to END.
The visual line is assumed to start at X0 and be monospaced with
characters CW pixels wide."
  (let (runs)
    (save-excursion
      (goto-char beg)
      (let ((col0 (current-column)))
        (while (progn (skip-chars-forward " \t\n" end) (< (point) end))
          (let ((x1 (+ x0 (* cw (- (current-column) col0)))))
            (skip-chars-forward "^ \t\n" end)
            (push (cons x1 (+ x0 (* cw (- (current-column) col0))))
                  runs)))))
    (nreverse runs)))

(defun critters--compute-surfaces (window)
  "Return a list of surfaces (Y X1 X2) for the text visible in WINDOW.
A surface is the top edge of a run of non-blank text with nothing
directly above it, low enough for the tallest critter to fit under
the top of the window.  The bottom of the window is always a
surface, marked as (Y X1 X2 floor).  It spans every X so a critter
can't miss it.

`posn-at-point' is slow, so it is only used once to find where
lines start horizontally.  The top of each line is read from the
glyph matrix with `window-line-height'.  Return nil if the glyph
matrix is not up to date."
  ;; Read the line positions first: moving around the buffer (with
  ;; font lock) makes `window-line-height' consider the glyph matrix
  ;; out of date.  Asking it for a row past the end of the window can
  ;; crash Emacs, so stay within it.
  (let ((ys (cl-loop for row below (window-body-height window)
                     for h = (window-line-height row window)
                     while h collect (nth 2 h))))
    (when ys
      (with-current-buffer (window-buffer window)
        (save-excursion
          (goto-char (window-start window))
          (let* ((posn (posn-at-point (point) window))
                 (x0 (if posn (car (posn-x-y posn)) 0))
                 (cw (window-font-width window))
                 (end (window-end window))
                 (above nil)
                 (surfaces (list (list (window-body-height window t)
                                       -1.0e+INF 1.0e+INF 'floor))))
            (while (and (< (point) end) ys)
              (let* ((y (pop ys))
                     (beg (point))
                     (next (progn (vertical-motion 1 window) (point)))
                     (runs (critters--line-runs beg (min next end) x0 cw)))
                (when (>= y critters--top)
                  (dolist (r (critters--subtract runs above))
                    (push (list y (car r) (cdr r)) surfaces)))
                (setq above runs)
                (when (<= next beg)
                  (goto-char end))))
            surfaces))))))

(defun critters--surfaces (window)
  "Return the surfaces of WINDOW, recomputing them only when needed."
  (let ((key (list window
                   (window-start window)
                   (window-hscroll window)
                   (window-body-width window t)
                   (window-body-height window t)
                   (buffer-chars-modified-tick (window-buffer window)))))
    (unless (equal key critters--surfaces-key)
      ;; Until redisplay catches up keep the old surfaces and retry.
      (let ((surfaces (critters--compute-surfaces window)))
        (when surfaces
          (setq critters--surfaces-key key
                critters--surfaces surfaces))))
    critters--surfaces))

(defun critters--surface-at (surfaces x y)
  "Return the one of SURFACES at height Y under X, or nil."
  (cl-loop for s in surfaces
           thereis (and (= (nth 0 s) y) (<= (nth 1 s) x) (< x (nth 2 s)) s)))

(defun critters--text-surfaces (surfaces)
  "Return SURFACES without the floor."
  (cl-remove-if (lambda (s) (nth 3 s)) surfaces))

(defun critters--nearest (surfaces x y)
  "Return the one of SURFACES closest to X, Y, ignoring those at height Y."
  (let (best best-d)
    (dolist (s surfaces best)
      (let* ((dx (max 0 (- (nth 1 s) x) (- x (nth 2 s))))
             (dy (- y (nth 0 s)))
             (d (+ (* dx dx) (* dy dy))))
        (when (and (/= dy 0) (or (null best-d) (< d best-d)))
          (setq best s
                best-d d))))))

(defun critters--landing (surfaces x y0 y1)
  "Return the height of the highest of SURFACES under X between Y0 and Y1."
  (let (best)
    (dolist (s surfaces best)
      (let ((y (nth 0 s)))
        (when (and (<= y0 y) (<= y y1)
                   (<= (nth 1 s) x) (< x (nth 2 s))
                   (or (null best) (< y best)))
          (setq best y))))))

;;;; Behavior

(defun critters--random-range (range)
  "Return a random number between the car and cdr of RANGE."
  (if (floatp (car range))
      (+ (car range) (* (- (cdr range) (car range)) (/ (random 1000) 1000.0)))
    (+ (car range) (random (1+ (- (cdr range) (car range)))))))

(defun critters--weighted (choices)
  "Return the car of a random element of CHOICES, an alist of (ITEM . WEIGHT)."
  (let ((r (random (apply #'+ (mapcar #'cdr choices)))))
    (cl-loop for (item . weight) in choices
             when (< r weight) return item
             do (cl-decf r weight))))

(defun critters--drop-in (pet)
  "Put PET down on a random bit of text in the current window.
Put it on the bottom of the window if there is no text, or if
`critters-style' is `bottom'."
  (let* ((text (unless (critters--bottom-p)
                 (critters--text-surfaces (critters--surfaces critters--window))))
         (s (and text (nth (random (length text)) text))))
    (setf (critters--pet-x pet)
          (float (if s
                     (+ (nth 1 s) (random (max 1 (- (nth 2 s) (nth 1 s)))))
                   (random (max 1 (window-body-width critters--window t)))))
          (critters--pet-y pet)
          (float (if s (nth 0 s) (window-body-height critters--window t)))
          (critters--pet-target pet) nil
          (critters--pet-vy pet) 0.0
          (critters--pet-state pet) 'ground)
    (critters--set-action pet 'idle (random 20))))

(defun critters--jump (pet surfaces)
  "Make PET jump towards a random text surface in SURFACES within reach.
If none is within reach, flying critters fly to the nearest one and
others hop in place."
  (let* ((lh (frame-char-height critters--parent))
         (lines (or (critters--pet-get pet :jump) 1))
         (fly (critters--pet-get pet :fly))
         (max-up (* lines lh))
         (max-dx (* lines 50))
         (x (critters--pet-x pet))
         (y (critters--pet-y pet))
         (text (critters--text-surfaces surfaces))
         (candidates (cl-remove-if-not
                      (lambda (s)
                        (and (/= (nth 0 s) y)
                             (<= (abs (- y (nth 0 s))) max-up)
                             (< (- (nth 1 s) max-dx) x (+ (nth 2 s) max-dx))))
                      text))
         (target (cond (candidates (nth (random (length candidates)) candidates))
                       (fly (critters--nearest text x y))))
         (ty (if target (nth 0 target) y))
         (tx (if target
                 (min (max (+ x (- (random (* 2 max-dx)) max-dx))
                           (nth 1 target))
                      (1- (nth 2 target)))
               x))
         ;; Arc peaking one line above the higher of the start and
         ;; the target.  Stepping once per tick the apex is reached
         ;; at v^2/2g - v/2 rather than v^2/2g, so solve for that.
         (g critters--gravity)
         (h (- y ty))
         (apex (+ (max h 0) lh))
         (v (+ (/ g 2) (sqrt (+ (/ (* g g) 4) (* 2 g apex))))))
    (setf (critters--pet-state pet) 'air
          (critters--pet-vy pet) (- v)
          (critters--pet-target pet) (and target (cons tx ty))
          (critters--pet-flapping pet) (and fly (> h (* 2 lh))))))

(defun critters--steer (pet)
  "Set the horizontal speed of PET to arrive at its target.
Aim for the moment it comes back down to the target's height, so
errors in the arc get corrected along the way."
  (let* ((g critters--gravity)
         (vy (critters--pet-vy pet))
         (target (critters--pet-target pet))
         (d (+ (* vy vy) (* 2 g (- (cdr target) (critters--pet-y pet))))))
    (when (>= d 0)
      (let ((ticks (max 1.0 (/ (+ (- vy) (sqrt d)) g))))
        (setf (critters--pet-vx pet)
              (max -8.0 (min 8.0 (/ (- (car target) (critters--pet-x pet))
                                    ticks))))))))

(defun critters--set-action (pet action ticks)
  "Make PET stand still doing ACTION for TICKS."
  (setf (critters--pet-action pet) action
        (critters--pet-action-ticks pet) ticks
        (critters--pet-vx pet) 0.0))

(defun critters--choose-action (pet surfaces)
  "Pick the next thing for grounded PET to do on SURFACES."
  (let ((on-floor (and (not (critters--bottom-p))
                       (nth 3 (critters--surface-at surfaces (critters--pet-x pet)
                                                    (critters--pet-y pet))))))
    (cond
     ;; Flying critters don't hang around on the floor, they get back
     ;; up onto the text.  Critters that can jump try to climb back up
     ;; half the time.
     ((and on-floor
           (or (critters--pet-get pet :fly)
               (and (critters--pet-get pet :jump) (zerop (random 2)))))
      (critters--set-action pet 'idle (+ 10 (random 20)))
      (critters--jump pet surfaces))
     ;; Settle down for the night.
     (critters--roosting
      (critters--set-action pet 'idle 900))
     (t
      (let ((action (critters--weighted
                     (if (critters--bottom-p)
                         (assq-delete-all 'jump (copy-alist (critters--pet-get pet :actions)))
                       (critters--pet-get pet :actions)))))
        (pcase action
          ('walk
           (setf (critters--pet-action pet) 'walk
                 (critters--pet-action-ticks pet)
                 (critters--random-range (critters--pet-get pet :walk-ticks))
                 (critters--pet-vx pet)
                 (* (if (zerop (random 2)) 1 -1)
                    (critters--random-range (critters--pet-get pet :walk)))))
          ('jump
           (critters--set-action pet 'idle (+ 10 (random 20)))
           (critters--jump pet surfaces))
          ('idle
           (critters--set-action pet 'idle (+ 15 (random 45))))
          (_
           (let ((pose (alist-get action (critters--pet-get pet :poses))))
             (critters--set-action pet action
                                   (critters--random-range (cdr pose)))))))))))

(defun critters--ground-step (pet surfaces ticks)
  "Advance grounded PET by TICKS on SURFACES.
TICKS is more than one only while every critter is standing still."
  (if (not (critters--surface-at surfaces (critters--pet-x pet)
                                 (critters--pet-y pet)))
      ;; The ground vanished (scroll, edit, a window popping up or
      ;; going away...), so snap down onto whatever is below.
      (let ((below (critters--landing surfaces (critters--pet-x pet)
                                      (critters--pet-y pet) 1.0e+INF)))
        (if below
            (setf (critters--pet-y pet) (float below))
          (setf (critters--pet-state pet) 'air)))
    (when (<= (cl-decf (critters--pet-action-ticks pet) ticks) 0)
      (critters--choose-action pet surfaces))
    (when (and (eq (critters--pet-state pet) 'ground)
               (eq (critters--pet-action pet) 'walk))
      (let ((nx (+ (critters--pet-x pet) (critters--pet-vx pet))))
        (cond
         ((critters--surface-at surfaces nx (critters--pet-y pet))
          (setf (critters--pet-x pet) nx))
         ;; At the end of the text, usually turn around.
         ((< (random 100) (critters--pet-get pet :edge-turn))
          (setf (critters--pet-vx pet) (- (critters--pet-vx pet))))
         (t
          (setf (critters--pet-x pet) nx
                (critters--pet-state pet) 'air
                (critters--pet-vy pet) 0.0)))))))

(defun critters--air-step (pet surfaces)
  "Advance airborne PET one tick on SURFACES."
  (let ((y0 (critters--pet-y pet))
        (top (critters--pet-h pet))
        (target (critters--pet-target pet)))
    (cl-incf (critters--pet-vy pet) critters--gravity)
    (when (> (critters--pet-vy pet) critters--max-fall)
      (setf (critters--pet-vy pet) critters--max-fall)
      (when (critters--pet-get pet :fly)
        (setf (critters--pet-flapping pet) t)))
    (when target
      (critters--steer pet))
    (cl-incf (critters--pet-x pet) (critters--pet-vx pet))
    (cl-incf (critters--pet-y pet) (critters--pet-vy pet))
    (when (< (critters--pet-y pet) top)
      (setf (critters--pet-y pet) (float top)
            (critters--pet-vy pet) 0.0))
    (when (>= (critters--pet-vy pet) 0)
      ;; Fly past anything above where we're aiming.
      (let ((landing (critters--landing surfaces (critters--pet-x pet)
                                        (if target (max y0 (cdr target)) y0)
                                        (critters--pet-y pet))))
        (when landing
          (setf (critters--pet-y pet) (float landing)
                (critters--pet-target pet) nil
                (critters--pet-vy pet) 0.0
                (critters--pet-state pet) 'ground
                (critters--pet-flapping pet) nil)
          (critters--set-action pet 'idle (random 20)))))))

;;;; Rendering

(defun critters--argb (color)
  "Convert COLOR name to an opaque ARGB32 integer."
  (pcase-let ((`(,r ,g ,b) (color-values color critters--parent)))
    (logior #xFF000000 (ash (ash r -8) 16) (ash (ash g -8) 8) (ash b -8))))

(defun critters--sprite-name (pet)
  "Return the name of the sprite frame to show for PET."
  (let ((ticks (+ critters--ticks (critters--pet-phase pet)))
        (action (critters--pet-action pet)))
    (cond
     ((eq (critters--pet-state pet) 'air)
      (cond ((critters--pet-get pet :fly)
             (if (and (critters--pet-flapping pet) (cl-oddp (/ ticks 3)))
                 'flap-down
               'flap-up))
            ((assq 'hop (critters--pet-sprites pet)) 'hop)
            (t 'stand)))
     ((eq action 'walk)
      (if (cl-oddp (/ ticks (critters--pet-get pet :step-ticks))) 'walk 'stand))
     ;; Asleep.
     (critters--roosting 'blink)
     ((assq action (critters--pet-get pet :poses))
      (car (alist-get action (critters--pet-get pet :poses))))
     ((< (% ticks 90) critters--calm-ticks) 'blink)
     (t 'stand))))

(defun critters--pet-sprite (pet)
  "Return the sprite (DATA . RECTS) to show for PET."
  (let ((pair (alist-get (critters--sprite-name pet) (critters--pet-sprites pet))))
    (if (> (critters--pet-facing pet) 0) (car pair) (cdr pair))))

(defun critters--render (pet)
  "Update the canvas of PET and move its child frame."
  (let ((sprite (critters--pet-sprite pet)))
    (unless (eq sprite (critters--pet-drawn pet))
      ;; The image spec has to stay the same object, so swap its data.
      (let ((image (critters--pet-image pet)))
        (plist-put (cdr image) :data (car sprite))
        (canvas-refresh image 'reload-data))
      (when (featurep 'critters-shape)
        (critters-shape-set (frame-parameter (critters--pet-frame pet) 'display)
                            (critters--pet-xid pet)
                            (cdr sprite)))
      (setf (critters--pet-drawn pet) sprite)))
  (let* ((edges (window-inside-pixel-edges critters--window))
         (left (+ (nth 0 edges) (round (critters--pet-x pet))
                  (- (/ (critters--pet-w pet) 2))))
         (top (+ (nth 1 edges) (round (critters--pet-y pet))
                 (- (critters--pet-h pet)))))
    (unless (and (eql left (critters--pet-left pet))
                 (eql top (critters--pet-top pet)))
      (setf (critters--pet-left pet) left
            (critters--pet-top pet) top)
      (set-frame-position (critters--pet-frame pet) left top))))

;;;; Main loop

(defun critters--target-window ()
  "Return the window the critters should be in."
  (let ((w (frame-selected-window critters--parent)))
    (cond ((not (window-minibuffer-p w)) w)
          ((window-live-p critters--window) critters--window)
          (t (frame-first-window critters--parent)))))

(defun critters--step-pet (pet surfaces ticks)
  "Advance PET by TICKS on SURFACES."
  (let ((half (/ (critters--pet-w pet) 2))
        (width (window-body-width critters--window t)))
    (if (eq (critters--pet-state pet) 'ground)
        (critters--ground-step pet surfaces ticks)
      (critters--air-step pet surfaces))
    ;; Bounce off the sides of the window.
    (when (or (< (critters--pet-x pet) half)
              (> (critters--pet-x pet) (- width half)))
      (setf (critters--pet-x pet)
            (float (max half (min (critters--pet-x pet) (- width half))))
            (critters--pet-vx pet) (- (critters--pet-vx pet))))
    (when (/= (critters--pet-vx pet) 0)
      (setf (critters--pet-facing pet) (if (> (critters--pet-vx pet) 0) 1 -1)))
    (critters--render pet)))

(defun critters--step (ticks)
  "Advance all the critters by TICKS."
  (let ((win (critters--target-window)))
    (unless (eq win critters--window)
      (setq critters--window win)
      (mapc #'critters--drop-in critters--active))
    (let* ((floor (window-body-height win t))
           (surfaces (if (critters--bottom-p)
                         (list (list floor -1.0e+INF 1.0e+INF 'floor))
                       (critters--surfaces win))))
      (cl-incf critters--ticks ticks)
      (dolist (pet critters--active)
        ;; If the window got shorter, don't fall out of the bottom.
        (when (> (critters--pet-y pet) floor)
          (setf (critters--pet-y pet) (float floor)
                (critters--pet-vy pet) 0.0))
        (critters--step-pet pet surfaces ticks)))))

(defun critters--shuffle (seconds)
  "Count SECONDS of animation towards the next turn, and take it if due.
The critter that has been out the longest goes to the back of the
queue, and the one at the front comes out on a random bit of text."
  (when (and critters--queue
             (>= (cl-incf critters--shuffle-time seconds)
                 critters-shuffle-interval))
    (setq critters--shuffle-time 0.0)
    (let ((leaving (pop critters--active))
          (coming (pop critters--queue)))
      (make-frame-invisible (critters--pet-frame leaving))
      (setq critters--queue (append critters--queue (list leaving)))
      (critters--drop-in coming)
      (critters--render coming)
      (make-frame-visible (critters--pet-frame coming))
      (setq critters--active (append critters--active (list coming))))))

(defun critters--calm-p ()
  "Return non-nil if every critter is standing still."
  (cl-every (lambda (pet)
              (and (eq (critters--pet-state pet) 'ground)
                   (not (eq (critters--pet-action pet) 'walk))))
            critters--active))

(defun critters--active-p ()
  "Return non-nil if the critters' frame is visible and focused.
Whether it's focused only counts with `critters-pause-when-unfocused'."
  (and (eq (frame-visible-p critters--parent) t)
       (or (not critters-pause-when-unfocused)
           (frame-focus-state critters--parent))))

(defun critters--schedule ()
  "Schedule the next tick, less often while every critter is calm."
  (setq critters--pending (if (critters--calm-p) critters--calm-ticks 1)
        critters--timer (run-at-time (/ critters--pending (float critters-fps))
                                     nil #'critters--tick)))

(defun critters--tick ()
  "Timer function: advance the critters and schedule the next tick.
Stop when the frame is hidden or unfocused, when the critters have
settled down to roost, or on errors."
  (condition-case err
      (cond
       ((not (frame-live-p critters--parent))
        (critters-mode -1))
       ((not (critters--active-p))
        (critters--sleep))
       (t
        (let ((idle (current-idle-time)))
          (when (and critters-roost-delay idle
                     (> (float-time idle) critters-roost-delay))
            (setq critters--roosting t)))
        (critters--step critters--pending)
        (when critters-shuffle
          (critters--shuffle (/ critters--pending (float critters-fps))))
        (cond
         ((and critters--roosting (critters--calm-p))
          (critters--sleep))
         ;; Not when called directly by `critters--wake'.
         (critters--timer
          (critters--schedule)))))
    (error
     (critters-mode -1)
     (message "critters: %s" (error-message-string err)))))

(defun critters--make-pet (n species overrides)
  "Create critter number N of SPECIES with breed palette OVERRIDES."
  (let* ((kind (alist-get species critters--species))
         (frames (plist-get kind :frames))
         (pet (critters--pet-create
               :kind kind
               :sprites (critters--build-sprites
                         frames
                         (append overrides (plist-get kind :palette))
                         (alist-get 'outline overrides
                                    (or (plist-get kind :outline)
                                        critters--outline))
                         critters--bg)
               :w (* critters-scale (length (cadr (car frames))))
               :h (* critters-scale (length (cdr (car frames))))
               :phase (random 90))))
    (critters--make-frame pet n)
    pet))

(defun critters--make-frame (pet n)
  "Create the child frame showing critter PET, which is number N."
  (let* ((w (critters--pet-w pet))
         (h (critters--pet-h pet))
         (bg-color (frame-parameter critters--parent 'background-color))
         (buf (get-buffer-create (format " *critters-%d*" n)))
         (image (create-image (make-vector (* w h) critters--bg)
                              'canvas t
                              :id (intern (format "critters-%d" n))
                              :data-width w
                              :data-height h
                              :scale 1))
         frame)
    (with-current-buffer buf
      (erase-buffer)
      (insert (propertize " " 'display image))
      (setq-local mode-line-format nil
                  auto-hscroll-mode nil
                  header-line-format nil
                  tab-line-format nil
                  cursor-type nil
                  cursor-in-non-selected-windows nil
                  truncate-lines t
                  line-spacing 0
                  display-line-numbers nil))
    ;; Without lowering the minimum window size Emacs enforces a frame
    ;; of at least 10 columns by 4 lines.
    (let ((after-make-frame-functions nil)
          (before-make-frame-hook nil)
          (window-min-width 1)
          (window-min-height 1)
          (frame-resize-pixelwise t))
      (setq frame
            (make-frame
             `((parent-frame . ,critters--parent)
               (minibuffer . nil)
               (undecorated . t)
               (no-accept-focus . t)
               (no-focus-on-map . t)
               (no-other-frame . t)
               (skip-taskbar . t)
               (unsplittable . t)
               (desktop-dont-save . t)
               (internal-border-width . 0)
               (child-frame-border-width . 0)
               (left-fringe . 0)
               (right-fringe . 0)
               (vertical-scroll-bars . nil)
               (horizontal-scroll-bars . nil)
               (menu-bar-lines . 0)
               (tool-bar-lines . 0)
               (tab-bar-lines . 0)
               (cursor-type . nil)
               (background-color . ,bg-color)
               (width . (text-pixels . ,w))
               (height . (text-pixels . ,h))
               (visibility . nil))))
      (let ((win (frame-root-window frame)))
        (set-window-buffer win buf)
        (set-window-dedicated-p win t)
        (set-window-hscroll win 0))
      ;; Emacs clips the last column of a line, so leave a spare
      ;; column or the right edge of the image is cut off.
      (set-frame-size frame (+ w (frame-char-width frame)) h t))
    (setf (critters--pet-frame pet) frame
          (critters--pet-xid pet) (string-to-number
                                   (frame-parameter frame 'outer-window-id))
          (critters--pet-image pet) image
          (critters--pet-buffer pet) buf)))

(defun critters--wake ()
  "Idle timer function: start animating until the next command."
  (when (and (not (timerp critters--timer))
             (frame-live-p critters--parent)
             (critters--active-p))
    (setq critters--roosting nil
          critters--pending 1)
    (critters--tick)
    (when critters-mode
      (dolist (pet critters--active)
        (make-frame-visible (critters--pet-frame pet)))
      (add-hook 'pre-command-hook #'critters--sleep)
      (critters--schedule))))

(defun critters--focus-change ()
  "Resume animating if the frame gets focus back while Emacs is idle."
  (let ((idle (current-idle-time)))
    (when (and idle (>= (float-time idle) critters-idle-delay))
      (critters--wake))))

(defun critters--sleep ()
  "Stop animating, leaving the critters frozen in place."
  (remove-hook 'pre-command-hook #'critters--sleep)
  (when (timerp critters--timer)
    (cancel-timer critters--timer))
  (setq critters--timer nil))

(defun critters--start ()
  "Hatch the critters in `critters-flock' in the selected frame."
  (dolist (entry critters-flock)
    (unless (assq (car entry) critters--species)
      (user-error "Unknown critter species: %s" (car entry))))
  (setq critters--parent (selected-frame)
        critters--bg (critters--argb (frame-parameter critters--parent
                                                      'background-color))
        critters--window nil
        critters--surfaces-key nil
        critters--ticks 0)
  (let ((n 0))
    (setq critters--pets
          (cl-loop for (species . count) in critters-flock
                   for breeds = (alist-get species critters-breeds)
                   nconc (cl-loop for i below count
                                  for breed = (nth (% i (max 1 (length breeds)))
                                                   breeds)
                                  collect (critters--make-pet n species (cdr breed))
                                  do (cl-incf n)))))
  (let ((out (if critters-shuffle
                 (min critters-shuffle-count (length critters--pets))
               (length critters--pets))))
    (setq critters--active (seq-take critters--pets out)
          critters--queue (seq-drop critters--pets out)
          critters--shuffle-time 0.0))
  (setq critters--top (apply #'max 0 (mapcar #'critters--pet-h critters--pets))
        critters--idle-timer
        (run-with-idle-timer critters-idle-delay t #'critters--wake))
  (add-function :after after-focus-change-function #'critters--focus-change))

(defun critters--stop ()
  "Remove the critters."
  (remove-function after-focus-change-function #'critters--focus-change)
  (critters--sleep)
  (when (timerp critters--idle-timer)
    (cancel-timer critters--idle-timer))
  (dolist (pet critters--pets)
    (when (frame-live-p (critters--pet-frame pet))
      (delete-frame (critters--pet-frame pet)))
    (when (buffer-live-p (critters--pet-buffer pet))
      (kill-buffer (critters--pet-buffer pet))))
  (setq critters--idle-timer nil
        critters--pets nil
        critters--active nil
        critters--queue nil))

;;;###autoload
(define-minor-mode critters-mode
  "Toggle critters that hop around the selected window."
  :global t
  (critters--stop)
  (when critters-mode
    (unless (display-graphic-p)
      (setq critters-mode nil)
      (user-error "Critters need a graphical frame"))
    (critters--start)))

(provide 'critters)
;;; critters.el ends here
