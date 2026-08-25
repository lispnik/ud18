(in-package #:ud18)

;;;; The command side of the protocol: frames the host writes TO the meter.
;;;;
;;;; Established in three steps, in this order, because the first two on their
;;;; own were misleading:
;;;;
;;;; 1. Black-box probing found the envelope and the checksum, and then hit a
;;;;    wall. The meter ACKs a well-formed frame and changes nothing visible,
;;;;    so no amount of sweeping opcodes revealed what they meant. Worse, an
;;;;    8-byte command -- correct envelope, correct checksum -- is discarded
;;;;    in silence, which reads exactly like "that opcode does nothing".
;;;; 2. Two public projects documented the ATORCH family protocol and supplied
;;;;    the missing shape: a command frame is TEN octets, not eight.
;;;; 3. Every command below was then replayed against a real UD18. That
;;;;    matters: the documented table is for the whole ATORCH family, and this
;;;;    unit rejects several of its entries outright.
;;;; 4. Finally the manufacturer's Android app (com.tang.etest.e_test) was
;;;;    decompiled, which settled the meanings. Its command builder is a
;;;;    ten-byte array with this exact checksum, and its button handlers bind
;;;;    49/50/51/52 to the SETUP, OK, [+] and [-] keys while its three reset
;;;;    dialogs name what each of 1/2/3 clears. That is where the names below
;;;;    come from; they are the vendor's own, not guesses.
;;;;
;;;; Frame layout, 10 octets:
;;;;
;;;;   off  len  field
;;;;   ---  ---  ---------------------------------------------
;;;;    0    2   FF 55
;;;;    2    1   class = 0x11 (command)
;;;;    3    1   device type = 0x03 (USB meter)
;;;;    4    1   command
;;;;    5    4   value, u32 big-endian (0 when the command takes none)
;;;;    9    1   checksum, the same rule as a report
;;;;
;;;; The meter answers every command it parses with an 8-octet class-0x02
;;;; reply, FF 55 02 01 <status> 00 00 <checksum>.

;;; --- commands ----------------------------------------------------------

(defconstant +cmd-reset-energy+   #x01 "Zero the accumulated W.h.")
(defconstant +cmd-reset-capacity+ #x02 "Zero the accumulated A.h.")
(defconstant +cmd-reset-duration+ #x03 "Zero the run-time clock.")
(defconstant +cmd-reset-all+      #x05
  "Zero every accumulator at once. Documented by the family protocol, and
this meter replies OK to it -- but the manufacturer's own app never sends it,
so what it actually clears here is not established.")
(defconstant +cmd-plus+           #x11
  "[+] key per the family protocol. This unit replies 'unsupported', and the
vendor app never sends it -- it uses 0x33 for every device type.")
(defconstant +cmd-minus+          #x12
  "[-] key per the family protocol. Unsupported here; see +CMD-PLUS+.")
(defconstant +cmd-set-backlight+  #x21 "Backlight seconds, 0-60. NOT this unit.")
(defconstant +cmd-set-price+      #x22 "Price per kW.h. NOT this unit.")
(defconstant +cmd-setup+          #x31 "SETUP key.")
(defconstant +cmd-enter+          #x32 "ENTER key.")
(defconstant +cmd-plus-usb+       #x33
  "[+] key. Cycles the display forward through its measurement pages.")
(defconstant +cmd-minus-usb+      #x34
  "[-] key. Cycles the display back through its measurement pages.")

(defparameter +commands+
  ;; name                  opcode              takes-value  support
  `((:reset-energy    ,+cmd-reset-energy+   nil :accepted)
    (:reset-capacity  ,+cmd-reset-capacity+ nil :accepted)
    (:reset-duration  ,+cmd-reset-duration+ nil :verified)
    (:reset-all       ,+cmd-reset-all+      nil :accepted)   ; not used by the vendor app
    (:plus            ,+cmd-plus+           nil :unsupported)
    (:minus           ,+cmd-minus+          nil :unsupported)
    (:set-backlight   ,+cmd-set-backlight+  t   :unsupported)
    (:set-price       ,+cmd-set-price+      t   :unsupported)
    (:setup           ,+cmd-setup+          nil :accepted)
    (:enter           ,+cmd-enter+          nil :accepted)
    (:plus-usb        ,+cmd-plus-usb+       nil :verified)
    (:minus-usb       ,+cmd-minus-usb+      nil :verified))
  "Every known command: (NAME OPCODE TAKES-VALUE SUPPORT).

SUPPORT is what the tested UD18 actually did, not what the family protocol
claims:

  :verified     sent, and its effect was observed happening -- either in the
                measurement stream (reset-duration zeroed the clock) or on the
                meter's screen (the [+]/[-] pair cycles the display pages).
  :accepted     the meter replied OK (status 0x01), so it parsed and accepted
                the command -- but the effect is on the display, which the
                measurement stream cannot see. Believed correct, not proven.
  :unsupported  the meter replied status 0x03. These are real ATORCH commands
                that this firmware does not implement; the [+]/[-] pair has
                separate USB-meter opcodes (0x33/0x34) which it does accept.")

(defun command-info (name)
  "The +COMMANDS+ entry for NAME, or NIL."
  (assoc name +commands+))

(defun command-opcode (name)
  "Opcode for a command NAME. Signals if NAME is not known."
  (let ((entry (command-info name)))
    (unless entry
      (error 'ud18-error))
    (second entry)))

(defun command-supported-p (name)
  "NIL when the tested unit answered 'unsupported' for this command."
  (not (eq (fourth (command-info name)) :unsupported)))

(defconstant +command-frame-length+ 10
  "A command frame is 10 octets. Anything shorter is discarded by the meter
without a reply -- which is exactly what makes a wrong guess here so hard to
spot, so it is a constant rather than an implicit 5 in a MAKE-OCTETS call.")

(defun encode-command (command &key (value 0) (device-type +device-usb+))
  "Build the 10-octet frame for COMMAND, which is a keyword from +COMMANDS+
or a raw opcode integer. VALUE is the 32-bit big-endian argument; commands
that take none ignore it.

Does not check whether the meter supports the command: an unsupported one is
answered with a status rather than doing damage, and refusing to encode it
would make it impossible to probe another ATORCH model with this library."
  (let ((opcode (if (integerp command) command (command-opcode command)))
        (body (make-octets 5)))
    (setf (aref body 0) opcode
          (aref body 1) (ldb (byte 8 24) value)
          (aref body 2) (ldb (byte 8 16) value)
          (aref body 3) (ldb (byte 8 8) value)
          (aref body 4) (ldb (byte 8 0) value))
    (encode-frame +class-command+ device-type body)))

;;; --- replies -----------------------------------------------------------

(defconstant +reply-frame-length+ 8)

(defparameter +reply-statuses+
  '((#x01 . :ok)
    (#x02 . :wrong-device-type)
    (#x03 . :unsupported)
    (#x05 . :wrong-message-class)
    (#x06 . :malformed))
  "Status byte -> meaning.

0x01 and 0x03 are documented. The other three were established here by
feeding the meter deliberately wrong frames and seeing which code came back:
a frame with a device-type other than 0x03 answers 0x02, one with a class
other than 0x11 answers 0x05, and a well-formed frame of the wrong length
answers 0x06. That last one is the useful one -- it is how you tell 'the
meter did not understand this command' from 'the meter did not accept this
frame at all'.")

(defstruct (reply (:constructor %make-reply))
  "A decoded class-0x02 reply."
  (raw (make-octets +reply-frame-length+) :type octets)
  (status-code 0 :type octet)
  (status :unknown))

(defun reply-frame-p (frame)
  "True when FRAME looks like a reply: right length, right magic, class 0x02,
and a checksum that validates."
  (and (= (length frame) +reply-frame-length+)
       (frame-magic-p frame)
       (= (frame-class frame) +class-reply+)
       (checksum-valid-p frame)))

(defun decode-reply (frame)
  "Decode a class-0x02 reply. Signals a FRAME-ERROR if FRAME is not one."
  (let ((frame (coerce-octets frame)))
    (unless (= (length frame) +reply-frame-length+)
      (error 'bad-length :frame frame :expected +reply-frame-length+ :actual (length frame)))
    (unless (frame-magic-p frame)
      (error 'bad-magic :frame frame))
    (unless (checksum-valid-p frame)
      (error 'bad-checksum :frame frame
                           :expected (frame-checksum frame)
                           :actual (aref frame (1- +reply-frame-length+))))
    (let ((code (aref frame 4)))
      (%make-reply :raw frame
                   :status-code code
                   :status (or (cdr (assoc code +reply-statuses+)) :unknown)))))
