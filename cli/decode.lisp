(in-package #:ud18.cli)

;;; `ud18 decode` -- offline frame decoding.
;;;
;;; The only subcommand with no BLE in it, which makes it the one that runs
;;; on a Mac. Takes hex frames from --hex, from files, or from stdin: the
;;; `hex` output format of monitor/record round-trips straight back in here.

(defun decode-one (hex fmt &key (verify t) (strict t))
  (let ((bytes (parse-hex-bytes hex)))
    (multiple-value-bind (r condition)
        (ud18:decode-frame-or-nil bytes :verify-checksum verify :strict strict)
      (cond (r (emit-reading *standard-output* r fmt)
               ;; Return the reading, not whatever EMIT-READING happened to
               ;; return: the callers count on this to tally what decoded.
               r)
            (t (write-string (undecodable-report condition bytes :label "skipped")
                             *error-output*)
               nil)))))

(defun decode-stream (in fmt &key (verify t) (strict t))
  "Decode every non-blank line of IN as one hex frame. Lines from a `hex`
capture may carry spaces; anything after a '#' is a comment."
  (let ((n 0))
    (loop for line = (read-line in nil nil)
          while line
          do (let* ((hash (position #\# line))
                    (text (string-trim '(#\Space #\Tab #\Return)
                                       (if hash (subseq line 0 hash) line))))
               (when (plusp (length text))
                 (when (decode-one text fmt :verify verify :strict strict)
                   (incf n)))))
    n))

(defun decode/handler (cmd)
  (let* ((fmt    (clingon:getopt cmd :format))
         (hex    (clingon:getopt cmd :hex))
         (verify (not (clingon:getopt cmd :no-verify)))
         (strict (not (clingon:getopt cmd :any-device)))
         (files  (clingon:command-arguments cmd))
         (n 0))
    (when (string= fmt "csv")
      (write-line (csv-header)))
    (cond
      (hex (when (decode-one hex fmt :verify verify :strict strict) (incf n)))
      (files
       (dolist (f files)
         (with-open-file (in f :if-does-not-exist nil)
           (if in
               (incf n (decode-stream in fmt :verify verify :strict strict))
               (format *error-output* "~&cannot open ~A~%" f)))))
      (t (incf n (decode-stream *standard-input* fmt :verify verify :strict strict))))
    (force-output)
    ;; Nothing decoded is a failure worth an exit code: `decode` is the piece
    ;; that ends up inside shell pipelines, where a silent success on a file
    ;; of garbage is the worst outcome.
    (when (zerop n)
      (format *error-output* "~&no frames decoded~%")
      (sb-ext:exit :code 1))))

(defun decode/options ()
  (list
   (clingon:make-option :string
                        :description "Decode this single hex frame instead of reading input"
                        :long-name "hex" :key :hex)
   (clingon:make-option :choice
                        :description "Output format"
                        :long-name "format" :items '("text" "jsonl" "csv" "hex")
                        :initial-value "text" :key :format)
   (clingon:make-option :flag
                        :description "Decode frames whose checksum does not match"
                        :long-name "no-verify" :key :no-verify)
   (clingon:make-option :flag
                        :description "Decode frames from device types other than 0x03 (unverified layout)"
                        :long-name "any-device" :key :any-device)))

(defun decode/command ()
  (clingon:make-command
   :name "decode"
   :description "decode captured hex frames offline (runs anywhere)"
   :usage "[--hex FF5501...] [--format text|jsonl|csv] [FILE ...]"
   :options (decode/options)
   :handler #'decode/handler))

(register-subcommand (decode/command))
