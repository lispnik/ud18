(in-package #:ud18/tests)

(in-suite protocol)

;;; The fixture is the real thing: every frame in captures/ud18-2026-08-19.hex
;;; came off the unit this protocol was reverse-engineered from. Tests that
;;; assert against hand-written bytes only prove the decoder agrees with
;;; whoever wrote the bytes.

(defparameter *capture-path*
  (asdf:system-relative-pathname :ud18/tests "captures/ud18-2026-08-19.hex"))

(defun hex->octets (string)
  (let* ((clean (remove-if-not (lambda (c) (digit-char-p c 16)) string))
         (out (make-array (floor (length clean) 2) :element-type '(unsigned-byte 8))))
    (dotimes (i (length out) out)
      (setf (aref out i)
            (parse-integer clean :start (* i 2) :end (+ (* i 2) 2) :radix 16)))))

(defun capture-frames ()
  (with-open-file (in *capture-path*)
    (loop for line = (read-line in nil nil)
          while line
          for text = (string-trim '(#\Space #\Tab #\Return) line)
          when (plusp (length text)) collect (hex->octets text))))

;;; One frame, spelled out, so a scaling change has to be deliberate.
;;; Decoded values cross-checked against the meter's own display.
(defparameter *sample-hex*
  "ff5501030004b000001c00b6a10000dca000d600ed000000c60b083c000000000000003b")

;;; --- framing -----------------------------------------------------------

(test frame-magic
  (let ((f (hex->octets *sample-hex*)))
    (is-true (ud18:frame-magic-p f))
    (is (= ud18::+class-report+ (ud18:frame-class f)))
    (is (= ud18::+device-usb+ (ud18:frame-device-type f))))
  (is-false (ud18:frame-magic-p (hex->octets "0000")))
  (is-false (ud18:frame-magic-p #())))

(test checksum-of-sample-frame
  (let ((f (hex->octets *sample-hex*)))
    (is (= #x3B (ud18:frame-checksum f)))
    (is-true (ud18:checksum-valid-p f))))

(test checksum-holds-across-the-whole-capture
  "Every frame the device actually sent must validate. This is the check
that pins the checksum algorithm down: sum bytes 2..n-2, low byte, XOR 0x44."
  (let ((frames (capture-frames)))
    (is (= 321 (length frames)) "fixture should hold 321 captured frames")
    (dolist (f frames)
      (is-true (ud18:checksum-valid-p f)
               "frame ~A failed its checksum" f))))

(test checksum-detects-a-flipped-bit
  (let ((f (copy-seq (hex->octets *sample-hex*))))
    (setf (aref f 6) (logxor (aref f 6) #x01))
    (is-false (ud18:checksum-valid-p f))))

(test encode-frame-round-trips
  (let ((f (hex->octets *sample-hex*)))
    (is (equalp f (ud18:encode-frame (ud18:frame-class f)
                                     (ud18:frame-device-type f)
                                     (subseq f 4 35))))))

(test encode-frame-appends-a-valid-checksum
  (let ((f (ud18:encode-frame #x11 #x03 #(#x01 #x00 #x00))))
    (is (= 8 (length f)))
    (is (equalp #(#xFF #x55 #x11 #x03) (subseq f 0 4)))
    (is-true (ud18:checksum-valid-p f))))

;;; --- decoding ----------------------------------------------------------

(test decode-sample-frame
  (let ((r (ud18:decode-frame (hex->octets *sample-hex*))))
    (is (eq :usb (ud18:reading-device-type r)))
    (is (= 12.00d0 (ud18:reading-volts r)))
    (is (= 0.28d0  (ud18:reading-amps r)))
    (is (< (abs (- 3.36d0 (ud18:reading-watts r))) 1d-9))
    (is (= 46753   (ud18:reading-capacity-mah r)))
    (is (= 46.753d0 (ud18:reading-capacity-ah r)))
    (is (= 564.80d0 (ud18:reading-energy-wh r)))
    (is (= 2.14d0  (ud18:reading-d-minus-volts r)))
    (is (= 2.37d0  (ud18:reading-d-plus-volts r)))
    (is (= 0       (ud18:reading-temperature-c r)))
    (is (= 198     (ud18:reading-run-hours r)))
    (is (= 11      (ud18:reading-run-minutes r)))
    (is (= 8       (ud18:reading-run-seconds r)))
    (is (string= "198:11:08" (ud18:format-run-time r)))
    (is (= (+ (* 198 3600) (* 11 60) 8) (ud18:reading-run-time-seconds r)))))

(test decode-keeps-the-raw-frame
  "Nothing decoded is load-bearing: the original octets survive, so a field
that turns out to be mislabelled can be re-read from a stored reading."
  (let* ((bytes (hex->octets *sample-hex*))
         (r (ud18:decode-frame bytes)))
    (is (equalp bytes (ud18:reading-raw r)))
    (is (= #x3C (ud18:reading-backlight-seconds r)))
    (is (string= "always on" (ud18:backlight-description r)))))

(test undecoded-tail-is-exposed-whole
  "The bytes with no known meaning are reachable as one run, because every
renderer prints them. The range shrank to 28-34 once the vendor app showed
byte 27 to be the backlight setting; if it ever changes shape again, the
output formats change with it."
  (let ((r (ud18:decode-frame (hex->octets *sample-hex*))))
    (is (= 28 (ud18:reading-undecoded-offset r)))
    (is (= 7 (length (ud18:reading-undecoded r))))
    ;; It must be exactly the frame's own bytes, not a reconstruction.
    (is (equalp (subseq (ud18:reading-raw r) 28 35) (ud18:reading-undecoded r)))))

(test bytes-28-to-34-are-zero-across-this-capture
  "The vendor app references these bytes nowhere, and every frame the unit
sent has them zero. Recorded as a fact about the capture rather than a claim
about the protocol -- a future capture that breaks this is a discovery."
  (dolist (f (capture-frames))
    (is (every #'zerop (ud18:reading-undecoded (ud18:decode-frame f))))))

(test backlight-setting-is-decoded-with-the-vendor-apps-three-cases
  "0 and 60 are the extremes, not durations -- the app renders them as
'always off' and 'always on'. A bare \"60 s\" would be actively wrong."
  (flet ((bl (byte27)
           (let ((f (copy-seq (hex->octets *sample-hex*))))
             (setf (aref f 27) byte27
                   (aref f 35) (ud18:frame-checksum f))
             (ud18:backlight-description (ud18:decode-frame f)))))
    (is (string= "always off" (bl 0)))
    (is (string= "always on"  (bl 60)))
    (is (string= "30 s"       (bl 30)))))

(test decode-every-captured-frame
  "The whole capture must decode without signalling, and stay inside the
envelope the unit can physically produce."
  (dolist (f (capture-frames))
    (let ((r (ud18:decode-frame f)))
      (is (<= 11d0 (ud18:reading-volts r) 13d0))
      (is (<= 0d0 (ud18:reading-amps r) 1d0))
      (is (<= 46000 (ud18:reading-capacity-mah r) 47000))
      (is (< (ud18:reading-run-minutes r) 60))
      (is (< (ud18:reading-run-seconds r) 60)))))

(test run-time-advances-one-second-per-frame
  "The seconds byte is what fixes the h/m/s field positions: it steps by one
per frame and carries into minutes at 60.

Not *every* step is one, and that is the radio's doing rather than the
decoder's: three of the 298 notifications in this capture never arrived, so
the clock jumps by two across each gap. The assertion is therefore that the
clock only ever moves forward, in small steps, and that the overwhelming
majority of those steps are exactly one second."
  (let* ((frames (nthcdr 22 (capture-frames)))   ; the single continuous run
         (times (mapcar (lambda (f) (ud18:reading-run-time-seconds (ud18:decode-frame f)))
                        frames))
         (deltas (loop for (a b) on times while b collect (- b a)))
         (ones (count 1 deltas)))
    (is (every (lambda (d) (<= 1 d 3)) deltas)
        "run time must advance, and never by more than a dropped frame or two")
    (is (> ones (* 0.95 (length deltas)))
        "~D of ~D steps were exactly one second" ones (length deltas))))

(test capacity-and-energy-agree-with-the-instantaneous-readings
  "An independent check on the scalings. The capacity and energy counters
are integrals of the current and power readings, so over a long capture
their slopes have to match the means of the instantaneous fields. They do,
to about one percent -- which is the quantisation floor of counters that
tick once every few seconds."
  (let* ((frames (nthcdr 22 (capture-frames)))   ; the single continuous run
         (readings (mapcar #'ud18:decode-frame frames))
         (first (first readings))
         (last (car (last readings)))
         (dt (- (ud18:reading-run-time-seconds last) (ud18:reading-run-time-seconds first)))
         (d-mah (- (ud18:reading-capacity-mah last) (ud18:reading-capacity-mah first)))
         (d-wh  (- (ud18:reading-energy-wh last) (ud18:reading-energy-wh first)))
         (mean-a (/ (reduce #'+ readings :key #'ud18:reading-amps) (length readings)))
         (mean-w (/ (reduce #'+ readings :key #'ud18:reading-watts) (length readings)))
         (integrated-a (/ (* d-mah 3.6d0) dt))    ; mAh over s -> A
         (integrated-w (/ (* d-wh 3600d0) dt)))
    (is (plusp dt))
    (is (< (abs (- integrated-a mean-a)) (* 0.05d0 mean-a))
        "capacity slope ~,4F A vs mean current ~,4F A" integrated-a mean-a)
    (is (< (abs (- integrated-w mean-w)) (* 0.05d0 mean-w))
        "energy slope ~,4F W vs mean power ~,4F W" integrated-w mean-w)))

;;; --- error handling ----------------------------------------------------

(test decode-rejects-a-short-frame
  (signals ud18:bad-length (ud18:decode-frame (hex->octets "ff5501030004b0"))))

(test decode-rejects-bad-magic
  (let ((f (copy-seq (hex->octets *sample-hex*))))
    (setf (aref f 0) #x00)
    (setf (aref f 35) (ud18:frame-checksum f))    ; keep the checksum honest
    (signals ud18:bad-magic (ud18:decode-frame f))))

(test decode-rejects-a-bad-checksum
  (let ((f (copy-seq (hex->octets *sample-hex*))))
    (setf (aref f 35) (logxor (aref f 35) #xFF))
    (signals ud18:bad-checksum (ud18:decode-frame f))
    (finishes (ud18:decode-frame f :verify-checksum nil))))

(test bad-checksum-reports-both-values
  (let ((f (copy-seq (hex->octets *sample-hex*))))
    (setf (aref f 35) #x00)
    (handler-case (progn (ud18:decode-frame f) (fail "should have signalled"))
      (ud18:bad-checksum (c)
        (is (= #x00 (ud18:bad-checksum-actual c)))
        (is (= #x3B (ud18:bad-checksum-expected c)))))))

(test decode-rejects-an-unverified-device-type
  (let ((f (copy-seq (hex->octets *sample-hex*))))
    (setf (aref f 3) #x02)                        ; the AC-meter type
    (setf (aref f 35) (ud18:frame-checksum f))
    (signals ud18:unsupported-device-type (ud18:decode-frame f))
    (let ((r (ud18:decode-frame f :strict nil)))
      (is (eq :unknown (ud18:reading-device-type r)))
      (is (= 12.00d0 (ud18:reading-volts r))))))

(test decode-frame-or-nil-returns-the-condition
  (multiple-value-bind (r c) (ud18:decode-frame-or-nil (hex->octets "ff55"))
    (is (null r))
    (is (typep c 'ud18:bad-length)))
  (multiple-value-bind (r c) (ud18:decode-frame-or-nil (hex->octets *sample-hex*))
    (is (ud18:reading-p r))
    (is (null c))))

;;; --- MAC handling ------------------------------------------------------

(test mac-parses-to-on-air-order
  "Addresses are held LSB-first everywhere inside the library, because that
is what BlueZ wants; the display order is the reversal."
  (let ((m (ble:parse-mac "CB:3B:7F:8E:75:A3")))
    (is (equalp #(#xA3 #x75 #x8E #x7F #x3B #xCB) m))
    (is (string= "CB:3B:7F:8E:75:A3" (ble:format-mac m)))))

(test mac-accepts-dashes-and-lowercase
  (is (equalp (ble:parse-mac "CB:3B:7F:8E:75:A3")
              (ble:parse-mac "cb-3b-7f-8e-75-a3"))))

(test mac-rejects-the-wrong-number-of-octets
  (signals ble:invalid-mac (ble:parse-mac "CB:3B:7F:8E:75")))

;;; --- commands ----------------------------------------------------------
;;;
;;; The expected frames are not invented: they are the exact byte sequences
;;; published for the ATORCH family, and each was replayed against a real
;;; UD18 during development. Testing the encoder against them is what pins
;;; the 10-octet frame down -- the meter discards a short command in silence,
;;; so a regression here would look like "the command stopped working" with
;;; nothing on the wire to say why.

(test command-frames-match-the-known-good-bytes
  (flet ((frame (name) (ud18:encode-command name)))
    (is (equalp (hex->octets "FF55110301000000 0051") (frame :reset-energy)))
    (is (equalp (hex->octets "FF55110302000000 0052") (frame :reset-capacity)))
    (is (equalp (hex->octets "FF55110303000000 0053") (frame :reset-duration)))
    (is (equalp (hex->octets "FF55110305000000 005D") (frame :reset-all)))
    (is (equalp (hex->octets "FF55110331000000 0001") (frame :setup)))
    (is (equalp (hex->octets "FF55110332000000 0002") (frame :enter)))
    (is (equalp (hex->octets "FF55110333000000 0003") (frame :plus-usb)))
    (is (equalp (hex->octets "FF55110334000000 000C") (frame :minus-usb)))))

(test every-command-frame-is-ten-octets-and-checksums
  (dolist (entry ud18:+commands+)
    (let ((f (ud18:encode-command (first entry))))
      (is (= ud18:+command-frame-length+ (length f))
          "~A encoded to ~D octets" (first entry) (length f))
      (is-true (ud18:checksum-valid-p f))
      (is (= #x11 (ud18:frame-class f)))
      (is (= #x03 (ud18:frame-device-type f))))))

(test command-value-is-a-32-bit-big-endian-argument
  ;; This exact frame was put on the wire and the meter parsed it (answering
  ;; "unsupported", which is a parse, not a rejection), so it is asserted
  ;; byte for byte.
  (is (equalp (hex->octets "FF551103210000001E17")
              (ud18:encode-command :set-backlight :value 30)))
  ;; No observed bytes for a large value, so assert the structure rather than
  ;; a checksum of my own arithmetic -- which is exactly the sort of thing a
  ;; test should not be quietly wrong about.
  (let ((f (ud18:encode-command :set-price :value 69420)))   ; #x00010F2C
    (is (equalp (hex->octets "00010F2C") (subseq f 5 9)))
    (is-true (ud18:checksum-valid-p f))))

(test raw-opcodes-encode-too
  "Probing another ATORCH model must not require adding it to the table."
  (is (equalp (ud18:encode-command :reset-energy) (ud18:encode-command #x01))))

(test unknown-command-name-is-an-error
  (signals ud18:ud18-error (ud18:encode-command :polish-the-screen)))

(test support-table-reflects-the-tested-unit
  (is-false (ud18:command-supported-p :plus))
  (is-false (ud18:command-supported-p :set-backlight))
  (is-true  (ud18:command-supported-p :plus-usb))
  (is-true  (ud18:command-supported-p :reset-duration)))

;;; --- replies -----------------------------------------------------------

(test decode-the-replies-the-meter-actually-sent
  "Each of these came back from the unit during probing; the status codes
beyond 0x01/0x03 were established by deliberately malforming frames."
  (flet ((status (hex) (ud18:reply-status (ud18:decode-reply (hex->octets hex)))))
    (is (eq :ok                  (status "FF55020101000040")))
    (is (eq :wrong-device-type   (status "FF55020102000041")))
    (is (eq :unsupported         (status "FF55020103000042")))
    (is (eq :wrong-message-class (status "FF5502010500004C")))
    (is (eq :malformed           (status "FF5502010600004D")))))

(test reply-keeps-its-raw-octets-and-code
  (let ((r (ud18:decode-reply (hex->octets "FF55020103000042"))))
    (is (= #x03 (ud18:reply-status-code r)))
    (is (equalp (hex->octets "FF55020103000042") (ud18:reply-raw r)))))

(test reply-frame-p-discriminates-replies-from-reports
  (is-true  (ud18:reply-frame-p (hex->octets "FF55020101000040")))
  (is-false (ud18:reply-frame-p (hex->octets *sample-hex*)))       ; a report
  (is-false (ud18:reply-frame-p (hex->octets "FF55020101000000"))) ; bad checksum
  (is-false (ud18:reply-frame-p (hex->octets "FF5502010100"))))    ; too short

(test decode-reply-rejects-a-report
  (signals ud18:bad-length (ud18:decode-reply (hex->octets *sample-hex*))))

(test characteristic-not-found-is-a-condition-callers-can-match
  "It was briefly a bare SIMPLE-ERROR, which left a caller wanting to retry
against the other address type matching on message text."
  (is (subtypep 'ud18:characteristic-not-found 'ud18:ud18-error))
  (handler-case
      (error 'ud18:characteristic-not-found :address "D0:D1:D2:D3:D4:D5"
                                            :found '("1800" "180A"))
    (ud18:characteristic-not-found (c)
      (is (string= "D0:D1:D2:D3:D4:D5" (ud18:characteristic-not-found-address c)))
      (is (equal '("1800" "180A") (ud18:characteristic-not-found-found c)))
      (let ((report (format nil "~A" c)))
        (is (search "really a UD18" report)
            "the report should say what it means, not just what is missing")
        (is (search "1800" report) "and list what the device did have")))))
