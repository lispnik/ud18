(in-package #:ud18.cli)

;;; `ud18 raw` -- send an arbitrary frame.
;;;
;;; The escape hatch that `ud18 command` deliberately is not. `command` knows
;;; the command set and will only build well-formed ten-byte frames for it;
;;; this builds whatever you describe, wraps it in FF 55 with a correct
;;; checksum, and shows you what came back.
;;;
;;; It earns its place because every structural fact in this project was found
;;; with exactly this capability. The meter's status codes for "wrong device
;;; type", "wrong message class" and "malformed frame" were mapped by sending
;;; deliberately wrong frames, and the ten-byte command length -- the single
;;; thing that made the command set reachable at all -- was found by sending
;;; the same opcode at several lengths and noticing which one drew a reply.
;;; A library that can only emit correct frames cannot discover what correct
;;; means.

(defun raw/handler (cmd)
  (let* ((body  (parse-hex-bytes (or (clingon:getopt cmd :body)
                                     (error "--body is required: hex, checksum excluded"))))
         (class (clingon:getopt cmd :class))
         (dtype (clingon:getopt cmd :device-type))
         (watch (clingon:getopt cmd :watch))
         (frame (ud18:encode-frame class dtype body)))
    (format t "~&frame: ~A  (~D octets)~%" (hex-string frame :separator " ") (length frame))
    (when (/= (length frame) ud18:+command-frame-length+)
      (format *error-output*
              "~&note: the meter accepts commands only at ~D octets and drops ~
                anything else~%      without a reply, so silence here is expected.~%"
              ud18:+command-frame-length+))
    (unless (clingon:getopt cmd :yes)
      (format *error-output* "~&Not sent. Re-run with --yes to transmit.~%")
      (return-from raw/handler))
    (let ((dev (resolve-dev (clingon:getopt cmd :dev)))
          (mac (or (clingon:getopt cmd :mac) (error "--mac is required"))))
      (with-meter (conn cmd mac dev)
        (ud18:send-raw-command conn body :class class :device-type dtype)
        (format *error-output* "~&Sent. Watching ~Ds...~%" watch)
        (force-output *error-output*)
        ;; Everything that is not a measurement report is shown raw, decoded
        ;; as a reply when it is one. A probe frame may well provoke something
        ;; that is neither.
        (let ((deadline (+ (get-internal-real-time)
                           (* watch internal-time-units-per-second)))
              (seen 0))
          (loop while (< (get-internal-real-time) deadline)
                for f = (ud18:next-frame conn :timeout-ms 500)
                do (when (and f (not (and (= (length f) 36)
                                          (ud18:frame-magic-p f)
                                          (= (ud18:frame-class f) 1))))
                     (incf seen)
                     (format t "~&recv:  ~A" (hex-string f :separator " "))
                     (if (ud18:reply-frame-p f)
                         (format t "   -> ~(~A~)~%"
                                 (ud18:reply-status (ud18:decode-reply f)))
                         (terpri))
                     (force-output)))
          (when (zerop seen)
            (format t "~&no response~%")))))))

(defun raw/options ()
  (append
   (connection/options)
   (list
    (clingon:make-option :string
                         :description "Frame body as hex: everything after the device-type byte, checksum excluded"
                         :long-name "body" :key :body)
    (clingon:make-option :integer
                         :description "Message class byte (17 = 0x11 command, 1 = report, 2 = reply)"
                         :long-name "class" :initial-value #x11 :key :class)
    (clingon:make-option :integer
                         :description "Device-type byte: 3 = USB meter, 1 = AC, 2 = DC"
                         :long-name "device-type" :initial-value #x03 :key :device-type)
    (clingon:make-option :integer
                         :description "Seconds to watch for a response"
                         :short-name #\w :long-name "watch" :initial-value 6 :key :watch)
    (clingon:make-option :flag
                         :description "Actually transmit. Without this the frame is only printed."
                         :long-name "yes" :key :yes))))

(defun raw/command ()
  (clingon:make-command
   :name "raw"
   :description "send an arbitrary framed probe (Linux only)"
   :usage "-m MAC --body HEX [--class N] [--device-type N] [--yes]"
   :options (raw/options)
   :handler #'raw/handler))

(register-subcommand (raw/command))
