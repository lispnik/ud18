(in-package #:ud18.cli)

;;; `ud18 monitor` -- connect to one meter and print readings as they arrive.

(defun monitor/handler (cmd)
  (let* ((mac  (or (clingon:getopt cmd :mac) (error "--mac is required")))
         (dev  (resolve-dev (clingon:getopt cmd :dev)))
         (secs (clingon:getopt cmd :seconds))
         (fmt  (clingon:getopt cmd :format))
         (stamp (clingon:getopt cmd :timestamps))
         (dump (clingon:getopt cmd :hexdump))
         (count 0))
    (format *error-output* "Connecting to ~A via hci~D...~%" mac dev)
    (force-output *error-output*)
    (with-meter (conn cmd mac dev)
      (format *error-output* "Connected (MTU ~D, value handle 0x~4,'0X). ~A~%"
              (ud18:connection-mtu conn) (ud18:connection-value-handle conn)
              (if secs (format nil "Reading for ~Ds." secs) "Ctrl-C to stop."))
      (force-output *error-output*)
      (with-interrupt-handler ()
        (ud18:stream-readings
         conn
         (lambda (r)
           (incf count)
           (emit-reading *standard-output* r fmt
                         :timestamp (when stamp (iso-timestamp)))
           (when dump
             (write-string (hexdump (ud18:reading-raw r) :indent "   ")))
           (force-output))
         :seconds secs
         ;; A frame that would not decode goes out in full. It is the only
         ;; record of whatever the meter just did that this library does not
         ;; understand, and one line of spaced hex loses the structure.
         :on-error (lambda (c raw)
                     (write-string (undecodable-report c raw) *error-output*)
                     (force-output *error-output*)))))
    (format *error-output* "~&~D reading~:P.~%" count)))

(defun monitor/options ()
  (append
   (connection/options)
   (list
    (clingon:make-option :integer
                         :description "Stop after N seconds (omit to run until Ctrl-C)"
                         :short-name #\s :long-name "seconds" :key :seconds)
    (clingon:make-option :choice
                         :description "Output format"
                         :long-name "format" :items '("text" "jsonl" "csv" "hex")
                         :initial-value "text" :key :format)
    (clingon:make-option :flag
                         :description "Prefix each line with an ISO-8601 UTC timestamp"
                         :short-name #\t :long-name "timestamps" :key :timestamps)
    (clingon:make-option :flag
                         :description "Hexdump every frame in full, not just the undecoded tail"
                         :short-name #\x :long-name "hexdump" :key :hexdump))))

(defun monitor/command ()
  (clingon:make-command
   :name "monitor"
   :description "stream live readings from a meter (Linux only)"
   :usage "-m MAC [--dev N] [--seconds N] [--format text|jsonl|csv|hex]"
   :options (monitor/options)
   :handler #'monitor/handler))

(register-subcommand (monitor/command))
