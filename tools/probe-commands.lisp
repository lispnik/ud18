;;;; Probe the UD18's command space, one opcode at a time, and report what
;;;; each one visibly does.
;;;;
;;;; Deliberately not a subcommand of bin/ud18. This is an instrument for
;;;; reverse engineering, it is destructive by nature, and it should take a
;;;; conscious act to run -- not a tab-complete away from `ud18 monitor`.
;;;;
;;;; A command frame is TEN octets: FF 55, class, device type, command, a
;;;; 32-bit value, checksum. The meter discards any other length in silence,
;;;; and that silence is indistinguishable from "that opcode does nothing" --
;;;; a sweep of sixteen opcodes at the wrong length produced no effect and no
;;;; reply, which read as sixteen dead commands and meant the device had never
;;;; read one of them. It validates the checksum too: a bad one is dropped
;;;; without a reply.
;;;;
;;;; This file used to say, emphatically, that the length was 36. That was an
;;;; intermediate wrong theory from the phase when padding to report-length
;;;; appeared to work; the real answer came from the vendor's Android app and
;;;; was confirmed on the meter. The frame is no longer built here at all --
;;;; UD18:ENCODE-COMMAND owns it, and it is unit-tested against byte sequences
;;;; captured from the wire. A tool that carries its own copy of a protocol
;;;; detail will eventually disagree with the library about it, and this one
;;;; did, for weeks, in a comment headed "THE THING THAT MATTERS".
;;;;
;;;; Method. Normally the meter only emits class-0x01 measurement frames at
;;;; 1 Hz. A command it accepts is answered with a class-0x02 reply, so there
;;;; are two signals per probe: the reply itself, and whatever changes in the
;;;; measurement stream. For each opcode we capture a baseline, send, capture
;;;; again, and diff -- watching the fields a command could plausibly touch:
;;;;
;;;;   - the accumulators (capacity, energy, run time). These only ever go UP
;;;;     on their own. Any decrease means we found a reset, and the sweep
;;;;     stops immediately rather than continuing to wipe things.
;;;;   - byte 27, the backlight timeout. A command that changes settings
;;;;     should move it.
;;;;   - the rest of the undecoded tail, bytes 28-34.
;;;;   - the frame class, in case a command elicits the reply frames
;;;;     (class 0x02) that the meter otherwise never sends.
;;;;
;;;; Voltage and current are deliberately NOT compared: they jitter with the
;;;; load and would produce nothing but false positives.
;;;;
;;;; Usage:
;;;;   sbcl --load tools/probe-commands.lisp --eval '(probe:run "MAC" :opcodes (list 2 3 4))'

(require :asdf)
;; This file lives in tools/, so the project is one directory up and the ble
;; checkout is a sibling of that. BLE_DIR overrides it, matching the Makefile.
;;
;; This registry is separate from the Makefile's and was missed when ble moved
;; out into its own repository, which left the tool unable to load at all --
;; the hazard of a build path that nothing in CI exercises.
(defparameter *here*
  (directory-namestring (or *load-truename* *default-pathname-defaults*)))
(defparameter *project* (truename (merge-pathnames "../" *here*)))
(defparameter *ble*
  (truename (or (uiop:getenv "BLE_DIR") (merge-pathnames "../ble/" *project*))))
(asdf:initialize-source-registry
 `(:source-registry (:tree ,*project*) (:directory ,*ble*)
   :ignore-inherited-configuration))
(asdf:load-system :ud18)

(defpackage #:probe (:use #:cl) (:export #:run))
(in-package #:probe)

(defstruct snap capacity energy runtime b27 tail replies reports)

(defun report-p (f)
  (and (= (length f) 36) (ud18:frame-magic-p f) (= (ud18:frame-class f) #x01)))

(defun capture (conn seconds)
  "Collect everything the meter sends for SECONDS, split into measurement
reports and anything else (which is where a reply shows up)."
  (let ((deadline (+ (get-internal-real-time)
                     (* seconds internal-time-units-per-second)))
        (reports nil) (replies nil))
    (loop while (< (get-internal-real-time) deadline)
          for f = (ud18:next-frame conn :timeout-ms 700)
          when f do (if (report-p f) (push f reports) (push f replies)))
    (setf reports (nreverse reports) replies (nreverse replies))
    (let ((last (car (last reports))))
      (flet ((field (fn) (when last (ignore-errors (funcall fn (ud18:decode-frame last))))))
        (make-snap :reports reports
                   :replies replies
                   :capacity (field #'ud18:reading-capacity-mah)
                   :energy   (field #'ud18:reading-energy-wh)
                   :runtime  (field #'ud18:reading-run-time-seconds)
                   :b27      (field #'ud18:reading-backlight-seconds)
                   :tail     (field #'ud18:reading-undecoded))))))

(defun hex (v) (format nil "~{~2,'0X~}" (coerce v 'list)))

(defun compare (before after)
  "Return (values CHANGES DESTRUCTIVE-P). CHANGES is a list of strings.

The accumulators and the clock are integrals: they climb on their own while
we wait, so an *increase* is the meter working normally and says nothing
about the command. Only a decrease is a signal, and it is a loud one -- these
fields have no legitimate way to go backwards, so a drop means a reset."
  (let ((changes nil) (destructive nil))
    (flet ((monotonic (label a b)
             (when (and (realp a) (realp b) (< b a))
               (push (format nil "~A: ~A -> ~A  (WENT BACKWARDS)" label a b) changes)
               (setf destructive t)))
           (exact (label a b)
             (when (and a b (not (equalp a b)))
               (push (format nil "~A: ~A -> ~A" label a b) changes))))
      (monotonic "capacity mAh" (snap-capacity before) (snap-capacity after))
      (monotonic "energy Wh"    (snap-energy before)   (snap-energy after))
      (monotonic "run seconds"  (snap-runtime before)  (snap-runtime after))
      (exact "backlight (byte 27)" (snap-b27 before) (snap-b27 after))
      (when (and (snap-tail before) (snap-tail after)
                 (not (equalp (snap-tail before) (snap-tail after))))
        (push (format nil "undecoded tail: ~A -> ~A"
                      (hex (snap-tail before)) (hex (snap-tail after)))
              changes)))
    (values (nreverse changes) destructive)))

(defun describe-reply (f)
  "Render a reply, naming its status when it is one we recognise."
  (if (ud18:reply-frame-p f)
      (let ((r (ud18:decode-reply f)))
        (format nil "~A  [status 0x~2,'0X ~(~A~)]"
                (hex f) (ud18:reply-status-code r) (ud18:reply-status r)))
      (format nil "~A  [not a well-formed reply]" (hex f))))

(defun probe-one (conn opcode &key (value 0) (settle 5) (baseline 4))
  "Send one command and report what changed. Returns :DESTRUCTIVE, :REPLIED,
:CHANGED, :NO-EFFECT, or :LOST.

VALUE is the command's 32-bit argument. Most take none; SET-BACKLIGHT and
SET-PRICE are the ones that do, so sweeping an opcode at several values is
how you tell a command that ignores its argument from one that does not."
  (let ((frame (ud18:encode-command opcode :value value)))
    (format t "~&~%=== opcode 0x~2,'0X ===~%  send ~A~%" opcode (hex frame))
    (force-output)
    (let ((before (capture conn baseline)))
      (unless (snap-reports before)
        (format t "  no baseline reports -- device is not streaming~%")
        (return-from probe-one :lost))
      (ble:att-write-command (ud18:connection-chan conn)
                              (ud18:connection-value-handle conn) frame)
      (let ((after (capture conn settle)))
        (dolist (r (snap-replies after))
          (format t "  REPLY ~A~%" (describe-reply r)))
        (cond
          ((null (snap-reports after))
           (format t "  !! device STOPPED streaming~%")
           :lost)
          (t
           (multiple-value-bind (changes destructive) (compare before after)
             (dolist (c changes) (format t "  ~A~%" c))
             (cond (destructive (format t "  !! DESTRUCTIVE~%") :destructive)
                   ((snap-replies after) :replied)
                   (changes :changed)
                   (t (format t "  no reply, no observable change~%") :no-effect)))))))))

(defun run (mac &key (dev 0) (transport :hci-user) (opcodes (list 2 3 4 5 6 7 8))
                     (value 0) (settle 5)
                     stop-on-destructive)
  "Probe each opcode in OPCODES against the meter at MAC.

STOP-ON-DESTRUCTIVE halts the sweep the first time an accumulator goes
backwards. Leave it NIL to map the whole space in one pass -- but note that
once the totals are zeroed, a *later* opcode that also resets them has much
less to move, so the detector gets blunter as the sweep goes on. Ordering
matters more than it looks.

A command can also knock the link down. That is a result, not a failure, so
the sweep reconnects and carries on rather than abandoning the remaining
opcodes."
  (let ((conn (ud18:connect mac :dev dev :transport transport))
        (results nil))
    (unwind-protect
         (progn
           (format t "~&connected; MTU ~D~%" (ud18:connection-mtu conn))
           (let ((base (capture conn 4)))
             (format t "baseline: ~A mAh, ~A Wh, ~A s, byte27 0x~2,'0X, tail ~A~%"
                     (snap-capacity base) (snap-energy base) (snap-runtime base)
                     (snap-b27 base) (hex (snap-tail base))))
           (dolist (op opcodes)
             (let ((r (probe-one conn op :value value :settle settle)))
               (push (cons op r) results)
               (when (and (eq r :destructive) stop-on-destructive)
                 (format t "~&~%STOPPING at opcode 0x~2,'0X~%" op)
                 (return))
               (when (eq r :lost)
                 (format t "~&  link lost; reconnecting...~%")
                 (force-output)
                 (ignore-errors (ud18:disconnect conn))
                 (sleep 3)
                 (setf conn (handler-case (ud18:connect mac :dev dev :transport transport)
                              (error (e)
                                (format t "  reconnect failed: ~A~%" e)
                                nil)))
                 (unless conn
                   (format t "~&STOPPING: cannot reconnect~%")
                   (return))))))
      (ignore-errors (when conn (ud18:disconnect conn))))
    (format t "~&~%SUMMARY~%")
    (dolist (r (reverse results))
      (format t "  0x~2,'0X  ~A~%" (car r) (cdr r)))
    (reverse results)))
