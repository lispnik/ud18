(in-package #:ud18)

;;;; ATORCH UD18 wire protocol.
;;;;
;;;; Reverse-engineered from a live unit (UD18_BLE, CB:3B:7F:8E:75:A3) by
;;;; subscribing to characteristic 0xFFE1 and correlating the frames against
;;;; the device's own display. See README.md for the derivation; the short
;;;; version of the evidence is in the field notes below.
;;;;
;;;; Every frame -- report, reply, or command -- has the same shape:
;;;;
;;;;   FF 55 <class> <device-type> <body...> <checksum>
;;;;
;;;; The checksum is the low byte of the sum of everything from <class> up to
;;;; (but not including) the checksum itself, XORed with 0x44. That was
;;;; verified against 99/99 captured frames and is the one thing here that is
;;;; certain beyond argument.
;;;;
;;;; A measurement report is class 0x01, device type 0x03 (USB meter), and is
;;;; always 36 bytes:
;;;;
;;;;   off  len  field                    scaling        confirmed?
;;;;   ---  ---  -----------------------  -------------  ----------
;;;;    0    2   FF 55 magic              --             yes
;;;;    2    1   class = 0x01 (report)    --             yes
;;;;    3    1   device type = 0x03 USB   --             yes
;;;;    4    3   voltage        u24be     /100 -> V      yes  (12.02 V rail)
;;;;    7    3   current        u24be     /100 -> A      yes  (display: 0.21 A)
;;;;   10    3   capacity       u24be     x1   -> mAh    yes  (display: 46.7 Ah)
;;;;   13    4   energy         u32be     /100 -> Wh     yes  (display: 565 Wh)
;;;;   17    2   D- voltage     u16be     /100 -> V      vendor app
;;;;   19    2   D+ voltage     u16be     /100 -> V      vendor app
;;;;   21    2   temperature    u16be     x1   -> C      vendor app (reads 0)
;;;;   23    2   run time hours u16be     x1   -> h      yes
;;;;   25    1   run time mins  u8                       yes
;;;;   26    1   run time secs  u8                       yes
;;;;   27    1   backlight secs u8                       vendor app
;;;;   28    7   unused, all zero         --             vendor app
;;;;   35    1   checksum                 --             yes
;;;;
;;;; "vendor app" means the field was read out of the manufacturer's own
;;;; Android app (com.tang.etest.e_test, "E-test" 2.0), decompiled. Its USB
;;;; branch parses exactly these offsets, which settles the fields that
;;;; instrumenting the meter could not:
;;;;
;;;;   * Temperature really is a 16-bit value at offset 21. The app renders it
;;;;     as "N C / N F" with the Fahrenheit conversion inline, so the unit is
;;;;     degrees Celsius and the scale is 1. It reads zero on the test unit,
;;;;     which is the meter's own answer and not a decode error.
;;;;   * Byte 27 is the backlight timeout in seconds, and the app gives it
;;;;     three cases: 0 is "always off", 60 is "always on", anything else is
;;;;     that many seconds. So the 0x3C this unit reports means the backlight
;;;;     never times out -- not "60 second timeout".
;;;;   * Bytes 28-34 are referenced nowhere in the app. Not "unknown": unused.
;;;;
;;;; Which of the pair at 17 and 19 is D- and which is D+ is still not settled.
;;;; The app displays both as bare voltages in TextViews it recycles from the
;;;; AC layout, so it never names them; the ordering here follows the family
;;;; protocol documentation.
;;;;
;;;; Field notes -- why the "confirmed" ones are confirmed:
;;;;
;;;; * The three accumulators cross-check each other. Over a 77 s capture the
;;;;   capacity counter advanced 4 units and the energy counter 6; their ratio
;;;;   pins energy-per-capacity at 12.08 "volts", which matches the measured
;;;;   12.02 V rail to within the quantisation error. That fixes the scalings
;;;;   *relative to each other* but leaves a global factor of ten free -- the
;;;;   physics is identical whether it is 0.21 A into 46.7 Ah or 0.021 A into
;;;;   4.67 Ah. The absolute scale comes from reading the unit's own display.
;;;;
;;;; * Run time: byte 26 increments exactly once per second and wraps at 60,
;;;;   at which point byte 25 increments. Watched across a minute boundary.
;;;;
;;;; * Bytes 17-20 track a pair of slowly-jittering ADC-looking values around
;;;;   2.1 V and 2.4 V that step together every few samples and are entirely
;;;;   uncorrelated with load -- the signature of the USB data lines being
;;;;   sampled. Which of the pair is D+ and which is D- follows the ordering
;;;;   ATORCH uses on its other meters; it has not been confirmed against a
;;;;   known-good source here, so treat the labels as provisional.
;;;;
;;;; * Bytes 21-22 read zero on the test unit, so the temperature reading is
;;;;   inferred from field position, not observation. DECODE-FRAME reports it
;;;;   as-is rather than hiding it.
;;;;
;;;; Anything marked "no" above is surfaced raw (READING-UNKNOWN-27,
;;;; READING-RESERVED) rather than given a name it has not earned.

;;; --- octet helpers -----------------------------------------------------

;;; OCTET, OCTETS, MAKE-OCTETS and COERCE-OCTETS come from #:ble (ble/core),
;;; which this package USES. They must not be redefined here: a DEFUN of an
;;; inherited name does not shadow it, it overwrites it.
;;;
;;; UBINT stays, because ble/core reads little-endian and ATORCH is
;;; big-endian. That is a protocol fact, not a missing primitive.

(defun ubint (bytes start length)
  "Unsigned big-endian integer of LENGTH octets from BYTES at START."
  (loop with acc = 0
        for i from start below (+ start length)
        do (setf acc (logior (ash acc 8) (aref bytes i)))
        finally (return acc)))

;;; --- conditions --------------------------------------------------------

(define-condition ud18-error (error) ()
  (:documentation "Base class for every error this library signals."))

(define-condition frame-error (ud18-error)
  ((frame :initarg :frame :reader frame-error-frame :initform nil))
  (:documentation "A frame could not be decoded. The offending octets, if
any, are available via FRAME-ERROR-FRAME."))

(define-condition bad-length (frame-error)
  ((expected :initarg :expected :reader bad-length-expected)
   (actual   :initarg :actual   :reader bad-length-actual))
  (:report (lambda (c s)
             (format s "UD18 frame is ~D bytes, expected ~D."
                     (bad-length-actual c) (bad-length-expected c)))))

(define-condition bad-magic (frame-error) ()
  (:report (lambda (c s)
             (let ((f (frame-error-frame c)))
               (format s "not a UD18 frame: expected FF 55 magic, got ~2,'0X ~2,'0X."
                       (if (plusp (length f)) (aref f 0) 0)
                       (if (> (length f) 1) (aref f 1) 0))))))

(define-condition bad-checksum (frame-error)
  ((expected :initarg :expected :reader bad-checksum-expected)
   (actual   :initarg :actual   :reader bad-checksum-actual))
  (:report (lambda (c s)
             (format s "UD18 frame checksum mismatch: frame carries 0x~2,'0X, computed 0x~2,'0X."
                     (bad-checksum-actual c) (bad-checksum-expected c)))))

(define-condition characteristic-not-found (ud18-error)
  ((address :initarg :address :reader characteristic-not-found-address)
   (found   :initarg :found   :reader characteristic-not-found-found))
  (:report (lambda (c s)
             (format s "characteristic 0xFFE1 not found on ~A; found ~{~A~^, ~}. ~
                        Is this really a UD18?"
                     (characteristic-not-found-address c)
                     (characteristic-not-found-found c))))
  (:documentation
   "CONNECT reached a device but it has no 0xFFE1 characteristic -- so it is
not a UD18, or not one in a state to talk.

A condition of its own because it is the one connect failure a caller can act
on: retrying against the other address type, or moving to the next device
from a scan, is sensible here and pointless for a timeout. It was briefly a
bare SIMPLE-ERROR, which left callers matching on the message text."))

(define-condition unsupported-device-type (frame-error)
  ((code :initarg :code :reader unsupported-device-type-code))
  (:report (lambda (c s)
             (format s "UD18: unsupported device type 0x~2,'0X (this library ~
                        decodes 0x03, the USB/DC meter)."
                     (unsupported-device-type-code c)))))

;;; --- framing -----------------------------------------------------------

(defconstant +frame-length+ 36
  "Length of a class-0x01 measurement report, in octets.")

(defconstant +magic-0+ #xFF)
(defconstant +magic-1+ #x55)
(defconstant +checksum-xor+ #x44
  "The constant the checksum sum is XORed with before transmission.")

(defconstant +class-report+  #x01 "Device -> host measurement report.")
(defconstant +class-reply+   #x02 "Device -> host reply to a command.")
(defconstant +class-command+ #x11 "Host -> device command.")

(defconstant +device-usb+ #x03
  "Device-type byte for the USB/DC meter family the UD18 belongs to.")

(defun frame-magic-p (frame)
  "True when FRAME starts with the FF 55 preamble every UD18 frame carries."
  (and (>= (length frame) 2)
       (= (aref frame 0) +magic-0+)
       (= (aref frame 1) +magic-1+)))

(defun frame-class (frame)
  "The message-class byte: +CLASS-REPORT+, +CLASS-REPLY+, or +CLASS-COMMAND+."
  (aref frame 2))

(defun frame-device-type (frame)
  "The device-type byte. 0x03 is the USB/DC meter the UD18 reports as."
  (aref frame 3))

(defun frame-checksum (frame)
  "Compute the checksum FRAME should carry in its last octet.

Sum every octet from the class byte (offset 2) up to but not including the
trailing checksum, take the low byte, XOR with 0x44."
  (let ((sum 0))
    (loop for i from 2 below (1- (length frame))
          do (incf sum (aref frame i)))
    (logxor (logand sum #xFF) +checksum-xor+)))

(defun checksum-valid-p (frame)
  "True when FRAME's trailing octet matches its computed checksum."
  (and (>= (length frame) 4)
       (= (aref frame (1- (length frame))) (frame-checksum frame))))

(defun encode-frame (class device-type body)
  "Build a complete frame: FF 55 CLASS DEVICE-TYPE BODY... CHECKSUM.

BODY is a sequence of octets -- everything between the device-type byte and
the checksum. The checksum is computed and appended for you.

Note that while the framing and the checksum are verified, the *contents* of
a command body are not: no command opcode has been confirmed against this
unit, deliberately, because the plausible candidates include \"reset the
accumulated totals\". This function is the honest primitive -- it will wrap
whatever you hand it, and it is on the caller to know what that means."
  (let* ((body (coerce-octets body))
         (frame (make-octets (+ 5 (length body)))))
    (setf (aref frame 0) +magic-0+
          (aref frame 1) +magic-1+
          (aref frame 2) class
          (aref frame 3) device-type)
    (replace frame body :start1 4)
    (setf (aref frame (1- (length frame))) (frame-checksum frame))
    frame))

;;; --- decoded measurement ----------------------------------------------

(defstruct (reading (:constructor %make-reading))
  "One decoded measurement report.

RAW keeps the original 36 octets so nothing decoded here is load-bearing: if
a field turns out to be mislabelled, the bytes are still there.
READING-UNDECODED exposes the tail that still has no known meaning."
  (raw            (make-octets +frame-length+) :type octets)
  (device-type    :usb)
  (volts          0d0 :type double-float)
  (amps           0d0 :type double-float)
  (capacity-mah   0   :type unsigned-byte)
  (energy-wh      0d0 :type double-float)
  (d-minus-volts  0d0 :type double-float)
  (d-plus-volts   0d0 :type double-float)
  (temperature-c  0   :type unsigned-byte)
  (run-hours      0   :type unsigned-byte)
  (run-minutes    0   :type unsigned-byte)
  (run-seconds    0   :type unsigned-byte)
  (backlight-seconds 0 :type octet))

(defun reading-watts (reading)
  "Instantaneous power, volts times amps. The meter does not transmit power
as its own field -- the display computes it the same way."
  (* (reading-volts reading) (reading-amps reading)))

(defun reading-capacity-ah (reading)
  "Accumulated charge in amp-hours."
  (/ (reading-capacity-mah reading) 1000d0))

(defun reading-run-time-seconds (reading)
  "Total elapsed run time in seconds, flattened from the h/m/s triple."
  (+ (* 3600 (reading-run-hours reading))
     (* 60 (reading-run-minutes reading))
     (reading-run-seconds reading)))

(defconstant +undecoded-start+ 28
  "Offset of the first octet of a report with no established meaning.

Bytes 28 to 34 are read by nothing -- not by this library, and not by the
manufacturer's own app, which references them zero times. They are zero on
every frame captured here.")

(defun reading-undecoded (reading)
  "The octets of this report that nothing is known to interpret: bytes 28
through 34, as one vector.

Still rendered by every output format, even now that the vendor app says they
are unused. Unused today is not unused in every firmware, and a byte that
starts changing should be visible the day it does rather than the day someone
thinks to re-read an old capture."
  (subseq (reading-raw reading) +undecoded-start+ (1- +frame-length+)))

(defun reading-undecoded-offset (reading)
  "Offset within the frame at which READING-UNDECODED begins."
  (declare (ignore reading))
  +undecoded-start+)

(defun backlight-description (reading)
  "The backlight setting in words. The vendor app treats 0 and 60 as the two
extremes rather than as durations, so a bare \"60 seconds\" would be wrong."
  (let ((n (reading-backlight-seconds reading)))
    (case n
      (0  "always off")
      (60 "always on")
      (t  (format nil "~D s" n)))))

(defun format-run-time (reading)
  "Run time as HHH:MM:SS."
  (format nil "~D:~2,'0D:~2,'0D"
          (reading-run-hours reading)
          (reading-run-minutes reading)
          (reading-run-seconds reading)))

(defun device-type-keyword (code)
  (case code
    (#x03 :usb)
    (t    :unknown)))

(defun decode-frame (frame &key (verify-checksum t) (strict t))
  "Decode a 36-byte measurement report into a READING.

Signals a subtype of FRAME-ERROR when FRAME is the wrong length, lacks the
FF 55 magic, fails its checksum, or carries a device type this library has
not been verified against.

VERIFY-CHECKSUM NIL accepts a frame whose checksum does not match, which is
occasionally what you want when replaying a damaged capture. STRICT NIL
likewise accepts an unrecognised device-type byte and decodes it with the
USB-meter layout anyway -- the shared prefix (voltage, current, capacity,
energy, run time) is believed common across the ATORCH family, but that has
not been tested here against anything but a UD18."
  (let ((frame (coerce-octets frame)))
    (unless (= (length frame) +frame-length+)
      (error 'bad-length :frame frame :expected +frame-length+ :actual (length frame)))
    (unless (frame-magic-p frame)
      (error 'bad-magic :frame frame))
    (when (and verify-checksum (not (checksum-valid-p frame)))
      (error 'bad-checksum :frame frame
                           :expected (frame-checksum frame)
                           :actual (aref frame (1- +frame-length+))))
    (let ((dt (frame-device-type frame)))
      (when (and strict (/= dt +device-usb+))
        (error 'unsupported-device-type :frame frame :code dt))
      (%make-reading
       :raw frame
       :device-type (device-type-keyword dt)
       :volts         (/ (ubint frame 4 3) 100d0)
       :amps          (/ (ubint frame 7 3) 100d0)
       :capacity-mah  (ubint frame 10 3)
       :energy-wh     (/ (ubint frame 13 4) 100d0)
       :d-minus-volts (/ (ubint frame 17 2) 100d0)
       :d-plus-volts  (/ (ubint frame 19 2) 100d0)
       :temperature-c (ubint frame 21 2)
       :run-hours     (ubint frame 23 2)
       :run-minutes   (aref frame 25)
       :run-seconds   (aref frame 26)
       :backlight-seconds (aref frame 27)))))

(defun decode-frame-or-nil (frame &rest args)
  "DECODE-FRAME, but return (VALUES NIL CONDITION) instead of signalling.
Convenient in a receive loop, where a malformed frame should be counted and
skipped rather than tear the stream down."
  (handler-case (values (apply #'decode-frame frame args) nil)
    (frame-error (c) (values nil c))))

;;; --- MAC addresses -----------------------------------------------------
;;;
;;; PARSE-MAC and FORMAT-MAC come from #:ble too. Addresses are held on-air
;;; (LSB first) everywhere inside both libraries, and those two functions are
;;; the single place the display order exists.
