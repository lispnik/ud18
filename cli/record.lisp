(in-package #:ud18.cli)

;;; `ud18 record` -- the same stream as `monitor`, to a file.
;;;
;;; Split from `monitor' rather than folded into it: a recorder wants a
;;; header, a flush policy, and a default format a spreadsheet or jq can
;;; read, and carrying all that in the interactive viewer makes both worse.

(defun record/handler (cmd)
  (let* ((mac   (or (clingon:getopt cmd :mac) (error "--mac is required")))
         (dev   (resolve-dev (clingon:getopt cmd :dev)))
         (secs  (clingon:getopt cmd :seconds))
         (fmt   (clingon:getopt cmd :format))
         (path  (clingon:getopt cmd :output))
         (append-p (clingon:getopt cmd :append))
         (utc   (clingon:getopt cmd :utc))
         (count 0))
    (with-open-file (out path :direction :output :element-type 'character
                              :if-exists (if append-p :append :supersede)
                              :if-does-not-exist :create)
      ;; A CSV needs its header once, and only when we are starting the file
      ;; rather than appending to one that already has it.
      (when (and (string= fmt "csv") (or (not append-p) (zerop (file-position out))))
        (write-line (csv-header :mac t) out))
      (format *error-output* "Connecting to ~A via hci~D...~%" mac dev)
      (force-output *error-output*)
      (with-meter (conn cmd mac dev)
        (format *error-output* "Connected. Recording ~A to ~A~A~%"
                fmt path (if secs (format nil " for ~Ds" secs) " (Ctrl-C to stop)"))
        (force-output *error-output*)
        (with-interrupt-handler ()
          (ud18:stream-readings
           conn
           (lambda (r)
             (incf count)
             (emit-reading out r fmt :timestamp (iso-timestamp :utc utc) :mac mac)
             ;; Flush every frame: a recording session normally ends with a
             ;; Ctrl-C or a pulled plug, and a buffered tail would be lost.
             (force-output out)
             (when (zerop (mod count 10))
               (format *error-output* "~&  ~D readings...~%" count)
               (force-output *error-output*)))
           :seconds secs
           :on-error (lambda (c raw)
                       (write-string (undecodable-report c raw) *error-output*)
                       (force-output *error-output*)
                       ;; A hex capture is meant to be lossless, so the bytes
                       ;; go in even though they did not decode. `decode`
                       ;; treats everything after a '#' as a comment, so the
                       ;; file still reads back cleanly.
                       (when (string= fmt "hex")
                         (format out "# ~A undecodable (~A): ~A~%"
                                 (iso-timestamp :utc utc) c
                                 (hex-string raw :separator " "))
                         (force-output out)))))))
    (format *error-output* "~&Wrote ~D reading~:P to ~A~%" count path)))

(defun record/options ()
  (append
   (connection/options)
   (list
    (clingon:make-option :integer
                         :description "Stop after N seconds (omit to run until Ctrl-C)"
                         :short-name #\s :long-name "seconds" :key :seconds)
    (clingon:make-option :string
                         :description "Output path"
                         :short-name #\o :long-name "output"
                         :initial-value "ud18.jsonl" :key :output)
    (clingon:make-option :choice
                         :description "Output format"
                         :long-name "format" :items '("jsonl" "csv" "text" "hex")
                         :initial-value "jsonl" :key :format)
    (utc/option)
    (clingon:make-option :flag
                         :description "Append to the output file instead of truncating it"
                         :long-name "append" :key :append))))

(defun record/command ()
  (clingon:make-command
   :name "record"
   :description "record live readings to a file (Linux only)"
   :usage "-m MAC -o OUT.jsonl [--format jsonl|csv|text|hex] [--seconds N]"
   :options (record/options)
   :handler #'record/handler))

(register-subcommand (record/command))
