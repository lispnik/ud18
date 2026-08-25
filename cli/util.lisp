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

(defun iso-timestamp (&optional ms-since-epoch)
  "ISO-8601 UTC timestamp, YYYY-MM-DDTHH:MM:SS.mmmZ, for MS-SINCE-EPOCH or now."
  (let ((ms (or ms-since-epoch
                (multiple-value-bind (s us) (sb-ext:get-time-of-day)
                  (+ (* s 1000) (floor us 1000))))))
    (multiple-value-bind (s millis) (truncate ms 1000)
      (multiple-value-bind (sec min hr day mon yr) (decode-universal-time (+ s 2208988800) 0)
        (format nil "~4,'0D-~2,'0D-~2,'0DT~2,'0D:~2,'0D:~2,'0D.~3,'0DZ"
                yr mon day hr min sec millis)))))

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

