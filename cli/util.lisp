(in-package #:ud18.cli)

(defun hex-string (vec &key (separator ""))
  "Uppercase hex for VEC, optionally separated."
  (with-output-to-string (s)
    (loop for i below (length vec)
          do (when (and (plusp i) (plusp (length separator)))
               (write-string separator s))
             (format s "~2,'0X" (aref vec i)))))

(defun hexdump (bytes &key (indent "  ") (base 0) (width 16))
  "Classic offset / hex / ASCII dump of BYTES, as a multi-line string with a
trailing newline. BASE is added to the printed offsets, so a dump of a slice
can still show where in the frame it came from.

The ASCII column is worth the width: the one thing most likely to be hiding
in an undecoded byte range is a string, and it is invisible in hex."
  (with-output-to-string (s)
    (loop for start from 0 below (max 1 (length bytes)) by width
          for end = (min (length bytes) (+ start width))
          do (format s "~A~4,'0X  " indent (+ base start))
             ;; Hex column, with the conventional gap at the halfway mark.
             (loop for i from start below (+ start width)
                   do (if (< i end)
                          (format s "~2,'0x " (aref bytes i))
                          (write-string "   " s))
                      (when (= (- i start) (1- (floor width 2)))
                        (write-char #\Space s)))
             (write-string " |" s)
             (loop for i from start below end
                   for b = (aref bytes i)
                   do (write-char (if (and (>= b #x20) (< b #x7F)) (code-char b) #\.) s))
             (format s "|~%"))))

(defun undecodable-report (condition raw &key (label "undecodable frame"))
  "A labelled hexdump of a frame that failed to decode, as a multi-line
string. This is the whole reason DECODE-FRAME-OR-NIL hands back the raw
octets alongside the condition: a frame we cannot read is exactly the frame
worth showing in full."
  (with-output-to-string (s)
    (format s "!! ~A, ~D byte~:P: ~A~%" label (length raw) condition)
    (write-string (hexdump raw :indent "   ") s)))

(defun parse-hex-bytes (string)
  "Parse a hex string (\"FF55\", \"FF 55\", \"ff:55\") into octets. Anything
that is not a hex digit is treated as a separator."
  (let* ((clean (remove-if-not (lambda (c) (digit-char-p c 16)) string))
         (n (length clean)))
    (when (oddp n)
      (error "hex string ~S has an odd number of hex digits" string))
    (let ((out (make-array (floor n 2) :element-type '(unsigned-byte 8))))
      (dotimes (i (floor n 2) out)
        (setf (aref out i)
              (parse-integer clean :start (* i 2) :end (+ (* i 2) 2) :radix 16))))))

(defconstant +unix-epoch-universal-time+ 2208988800
  "Universal time at 1970-01-01T00:00:00Z, the offset between CL's epoch and
the Unix one.")

(defun current-ms ()
  "Milliseconds since the Unix epoch, now."
  (multiple-value-bind (s us) (sb-ext:get-time-of-day)
    (+ (* s 1000) (floor us 1000))))

(defun utc-offset-minutes (universal-time)
  "Minutes east of UTC for UNIVERSAL-TIME in the host's local zone.

DECODE-UNIVERSAL-TIME hands back the zone as hours *west* of Greenwich and
in *standard* time, reporting daylight saving separately rather than folding
it in -- so the hour it also returns is already shifted for DST while the
zone is not. Subtracting the daylight hour is what reconciles the two; skip
it and every timestamp taken in summer is off by one."
  (multiple-value-bind (sec min hr day mon yr dow daylight-p zone)
      (decode-universal-time universal-time)
    (declare (ignore sec min hr day mon yr dow))
    (round (* -60 (- zone (if daylight-p 1 0))))))

(defun iso-timestamp (&key ms utc)
  "ISO-8601 timestamp for MS milliseconds since the Unix epoch, or for now.

With UTC, the Zulu form: YYYY-MM-DDTHH:MM:SS.mmmZ. Otherwise the host's
local time carrying its numeric offset, YYYY-MM-DDTHH:MM:SS.mmm+HH:MM.

Both are ISO-8601 and both name the same instant. What this will not emit is
a local time with no offset on it -- that is the one shape that cannot be
placed on a real timeline afterwards, and a measurement log is exactly where
that ambiguity does the most damage."
  (let ((ms (or ms (current-ms))))
    (multiple-value-bind (secs millis) (floor ms 1000)
      (let* ((ut (+ secs +unix-epoch-universal-time+))
             (offset (if utc 0 (utc-offset-minutes ut))))
        ;; Decode at zone 0 having shifted by the offset: local wall-clock
        ;; time is simply UTC plus the offset, and going through zone 0
        ;; keeps one code path for both forms.
        (multiple-value-bind (sec min hr day mon yr)
            (decode-universal-time (+ ut (* offset 60)) 0)
          (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D.~3,'0D~A"
                  yr mon day hr min sec millis
                  (if utc
                      "Z"
                      (format nil "~A~2,'0D:~2,'0D"
                              (if (minusp offset) "-" "+")
                              (floor (abs offset) 60)
                              (mod (abs offset) 60)))))))))

(defun zone-marker-position (s)
  "Index of the zone designator in S -- the 'Z', '+' or '-' that ends an
ISO-8601 timestamp -- searched from past the date, where a '-' is a
separator rather than a sign."
  (position-if (lambda (c) (member c '(#\Z #\z #\+ #\-))) s :start 19))

(defun iso-timestamp-p (string)
  "STRING trimmed when it has the shape ISO-TIMESTAMP writes, else NIL.

A shape check, not a parse: the point is only to tell a timestamp comment
apart from the other things a '#' comment in a capture may hold -- an
undecodable-frame note, or a line someone typed -- before handing it on as
a measurement time. Anything that does not look like one is left alone.

Both zone forms pass, Zulu and a numeric offset, because both are what this
tool writes and a capture may hold either."
  (let ((s (string-trim '(#\Space #\Tab #\Return) string)))
    (and (>= (length s) 20)
         (char= (char s 4) #\-) (char= (char s 7) #\-)
         (char= (char s 10) #\T)
         (char= (char s 13) #\:) (char= (char s 16) #\:)
         (loop for i in '(0 1 2 3 5 6 8 9 11 12 14 15 17 18)
               always (digit-char-p (char s i)))
         (let ((mark (zone-marker-position s)))
           (and mark
                (if (member (char s mark) '(#\Z #\z))
                    (= (length s) (1+ mark))
                    ;; +HH:MM -- an offset with no minutes field is legal
                    ;; ISO-8601 but is not something this tool emits, and
                    ;; accepting it would mean guessing at the rest.
                    (and (= (length s) (+ mark 6))
                         (char= (char s (+ mark 3)) #\:)
                         (loop for i in (list (+ mark 1) (+ mark 2)
                                              (+ mark 4) (+ mark 5))
                               always (digit-char-p (char s i)))))))
         s)))

(defun parse-iso-timestamp (string)
  "Milliseconds since the Unix epoch for STRING, or NIL if it is not a
timestamp of the shape ISO-TIMESTAMP-P accepts.

The offset is subtracted rather than ignored, which is the whole point: a
capture recorded in one zone and re-presented in another has to name the
same instant afterwards, or --utc would be rewriting history instead of
restating it."
  (let ((s (iso-timestamp-p string)))
    (when s
      (flet ((num (a b) (parse-integer s :start a :end b)))
        (let* ((mark   (zone-marker-position s))
               (millis (if (and (> mark 20) (char= (char s 19) #\.))
                           (num 20 (min mark 23))
                           0))
               (offset (if (member (char s mark) '(#\Z #\z))
                           0
                           (* (if (char= (char s mark) #\-) -1 1)
                              (+ (* 60 (num (+ mark 1) (+ mark 3)))
                                 (num (+ mark 4) (+ mark 6)))))))
          (+ (* 1000 (- (encode-universal-time (num 17 19) (num 14 16) (num 11 13)
                                               (num 8 10) (num 5 7) (num 0 4)
                                               0)
                        +unix-epoch-universal-time+
                        (* offset 60)))
             millis))))))

(defun present-timestamp (timestamp &key utc)
  "TIMESTAMP as recorded, or restated in UTC when UTC.

Restated, not relabelled: an unparseable timestamp is passed through
untouched rather than stamped with a 'Z' it has not earned."
  (if (and utc timestamp)
      (let ((ms (parse-iso-timestamp timestamp)))
        (if ms (iso-timestamp :ms ms :utc t) timestamp))
      timestamp))

(defmacro with-interrupt-handler ((&key (message "~&Interrupted.~%")) &body body)
  "Run BODY with Ctrl-C trapped: print MESSAGE and fall through."
  `(handler-case (progn ,@body)
     (sb-sys:interactive-interrupt ()
       (format *error-output* ,message))))

(defun resolve-dev (value)
  "The adapter index to use: VALUE if the user named one, else the lowest
adapter present.

:LOWEST rather than the library default of :USB, and that is not laziness.
BLE:DEFAULT-HCI-DEV defaults to a USB dongle because reaching the Coded PHY
usually needs one, and built-in radios generally cannot receive it. The UD18
has no such requirement -- it is an ordinary 1M-PHY advertiser -- and on the
development Pi the built-in radio is in fact the ONLY one that hears it,
while both USB dongles report nothing at all."
  (or value (ble:default-hci-dev nil :lowest)))

(defun addr-type-keyword (string)
  (cond ((string-equal string "public") :public)
        ((string-equal string "random") :random)
        (t (error "--addr-type must be 'public' or 'random', got ~S" string))))

(defun addr-type-label (n)
  (case n (0 "public") (1 "random") (t (format nil "type~D" n))))

;;; --- shared connection options ---------------------------------------
;;;
;;; monitor, record and send all open the same kind of connection, so the
;;; options that describe one live here rather than in whichever subcommand
;;; happened to need them first.

(defun utc/option ()
  "The --utc flag, shared by every subcommand that puts a time on a reading."
  (clingon:make-option :flag
                       :description "Timestamp in UTC (...Z) instead of local time with a UTC offset"
                       :long-name "utc" :key :utc))

(defun connection/options ()
  "Options shared by every subcommand that opens a connection."
  (list
   (clingon:make-option :string
                        :description "Meter MAC in display order, e.g. CB:3B:7F:8E:75:A3"
                        :short-name #\m :long-name "mac" :key :mac)
   (clingon:make-option :integer
                        :description "HCI adapter index (default: lowest present; try each with `ud18 scan`)"
                        :short-name #\d :long-name "dev" :key :dev)
   (clingon:make-option :choice
                        :description "Peer address type (ud18 scan prints what your meter uses)"
                        :long-name "addr-type" :items '("public" "random")
                        :initial-value "public" :key :addr-type)
   (clingon:make-option :choice
                        :description "LE transport: hci-user takes the adapter over (works everywhere); l2cap asks the kernel (less invasive, but does not connect on every host)"
                        :long-name "transport" :items '("hci-user" "l2cap")
                        :initial-value "hci-user" :key :transport)
   (clingon:make-option :integer
                        :description "Extra connection attempts before giving up"
                        :long-name "retries" :initial-value 1 :key :retries)))

(defun transport-keyword (string)
  (if (string-equal string "l2cap") :l2cap :hci-user))

(defmacro with-meter ((var cmd mac dev) &body body)
  "Open a connection to MAC using CMD's shared connection options, run BODY,
and close it however BODY leaves -- including the adapter handback that the
hci-user transport owes the kernel."
  `(let ((,var (open-meter ,cmd ,mac ,dev)))
     (unwind-protect (progn ,@body)
       (ud18:disconnect ,var))))

(defun open-meter (cmd mac dev)
  "Open a connection using the shared connection options on CMD."
  (ud18:connect mac :dev dev
                    :addr-type (addr-type-keyword (clingon:getopt cmd :addr-type))
                    :transport (transport-keyword (clingon:getopt cmd :transport))
                    :retries (clingon:getopt cmd :retries)))

