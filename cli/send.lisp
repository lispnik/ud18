(in-package #:ud18.cli)

;;; `ud18 command` -- send one of the meter's commands.
;;;
;;; The command set is real and verified (see README), but three of the four
;;; resets are irreversible and there is no undo on a device whose whole job
;;; is to accumulate a number over weeks. So a command that resets refuses to
;;; run without --yes, and every invocation prints the exact frame first.

(defun destructive-command-p (name)
  (member name '(:reset-energy :reset-capacity :reset-duration :reset-all)))

(defun command-name-from-string (s)
  (let* ((key (intern (string-upcase (substitute #\- #\_ s)) :keyword)))
    (if (ud18:command-info key)
        key
        ;; Also accept a raw opcode, so this stays usable for probing a model
        ;; whose commands are not in the table.
        (handler-case (parse-integer s :radix 16)
          (error ()
            (error "unknown command ~S. Known: ~{~(~A~)~^, ~} (or a hex opcode)"
                   s (mapcar #'first ud18:+commands+)))))))

(defun list-commands ()
  (format t "~&~14A ~8A ~10A ~A~%" "NAME" "OPCODE" "VALUE" "ON THE TESTED UD18")
  (dolist (entry ud18:+commands+)
    (destructuring-bind (name opcode takes-value support) entry
      (format t "~14A 0x~2,'0X   ~10A ~A~%"
              (string-downcase (symbol-name name)) opcode
              (if takes-value "required" "-")
              (case support
                (:verified    "verified -- effect observed")
                (:accepted    "accepted (reply OK; effect not independently confirmed)")
                (:unsupported "UNSUPPORTED -- meter replies 0x03")
                (t support))))))

(defun split-commands (s)
  "Split a comma-separated command list; the whole list goes out on one
connection. That saves the per-command connect -- about fifteen seconds each
on the Coded-PHY link -- and keeps a sequence of commands close together in
time, which matters on a meter whose reply rate drifts. See README."
  (loop with start = 0
        for i = (position #\, s :start start)
        collect (string-trim " " (subseq s start i))
        while i do (setf start (1+ i))))

(defun send-one (conn name value dtype cmd)
  "Send one command on an existing connection. Returns an exit code."
  (let ((frame (ud18:encode-command name :value value :device-type dtype)))
    (format t "~&frame: ~A~%" (hex-string frame :separator " ")))
  (multiple-value-bind (reply raw delivery notifying)
      (ud18:send-command conn name :value value :device-type dtype
                         :write-mode (if (clingon:getopt cmd :no-ack)
                                         :command :request)
                         :require-notify (not (clingon:getopt cmd :anyway)))
    (report-outcome reply raw delivery notifying)))

(defun send/handler (cmd)
  (when (clingon:getopt cmd :list)
    (list-commands)
    (return-from send/handler))
  (let* ((name-string (or (clingon:getopt cmd :command)
                          (error "--command is required (try --list)")))
         (names (mapcar #'command-name-from-string (split-commands name-string)))
         (value (clingon:getopt cmd :value))
         (dtype (clingon:getopt cmd :device-type))
         (repeat (max 1 (clingon:getopt cmd :repeat))))
    (dolist (name names)
      (when (and (keywordp name) (not (ud18:command-supported-p name)))
        (format *error-output*
                "~&note: the tested UD18 answers 'unsupported' for ~(~A~). ~
                  Sending anyway.~%" name))
      (when (and (keywordp name) (destructive-command-p name)
                 (not (clingon:getopt cmd :yes)))
        (format *error-output*
                "~&Not sent: ~(~A~) is irreversible. Re-run with --yes.~%" name)
        (return-from send/handler)))
    (let ((dev (resolve-dev (clingon:getopt cmd :dev)))
          (mac (or (clingon:getopt cmd :mac) (error "--mac is required")))
          (worst 0))
      ;; One connection for every command in the batch.
      (with-meter (conn cmd mac dev)
        (dotimes (pass repeat)
          (dolist (name names)
            (let ((code (send-one conn name value dtype cmd)))
              (setf worst (max worst code))))))
      (unless (zerop worst) (sb-ext:exit :code worst)))))

(defun report-outcome (reply raw delivery notifying)
  "Print what happened to one command and return the exit code for it.

  0 replied OK
  1 the meter refused the command
  2 delivered, but no reply -- inconclusive
  3 the write did not land
  4 nothing was transmitted, or could not have been answered"
  (cond
    ;; Nothing went out, so the retry is free.
    ((eq delivery :not-sent)
     (format t "~&NOT SENT: the meter is connected and accepting writes, but ~
                it is~%sending no notifications at all -- not even ~
                measurement reports --~%so no reply could come back. Nothing ~
                was transmitted; the command~%is safe to re-run. This often ~
                clears by itself within seconds; if it~%persists, power-cycle ~
                the meter. (--anyway sends regardless.)~%")
     4)
    ((eq delivery :timeout)
     (format t "~&NOT SENT: the meter did not acknowledge the write, so the ~
                command~%did not reach it. Safe to retry.~%")
     3)
    ((integerp delivery)
     (format t "~&REFUSED: the meter rejected the write with ATT error ~
                0x~2,'0X.~%" delivery)
     3)
    ;; Only reachable with --anyway: the write landed on a link that cannot
    ;; answer, so it may well have been acted on with no way to confirm it.
    ((and (null reply) (null notifying) (eq delivery :acknowledged))
     (format t "~&NOT NOTIFYING: the meter acknowledged the write, so it HAS ~
                the command,~%but it is sending no notifications at all. No ~
                reply could have arrived.~%Assume it may have acted; do NOT ~
                blindly retry.~%")
     4)
    ((null reply)
     (format t "~&no reply within the timeout -- INCONCLUSIVE.~%")
     (if (eq delivery :acknowledged)
         (format t "The write WAS acknowledged and the meter is notifying ~
                    normally, so it~%had the command and chose not to answer. ~
                    Assume it may have acted.~%")
         (format t "Sent without acknowledgement (--no-ack), so nothing can ~
                    be concluded about~%whether it arrived. Re-run without ~
                    --no-ack to tell the two cases apart.~%"))
     2)
    (t
     (format t "~&reply: ~A  ->  ~(~A~)~%"
             (hex-string raw :separator " ") (ud18:reply-status reply))
     (if (eq (ud18:reply-status reply) :ok) 0 1))))

(defun send/options ()
  (append
   (connection/options)
   (list
    (clingon:make-option :string
                         :description "Command name (see --list), a raw hex opcode, or a comma-separated list sent on one connection"
                         :short-name #\c :long-name "command" :key :command)
    (clingon:make-option :integer
                         :description "32-bit argument for commands that take one"
                         :long-name "value" :initial-value 0 :key :value)
    (clingon:make-option :integer
                         :description "Device-type byte: 3 = USB meter (this one), 1 = AC, 2 = DC"
                         :long-name "device-type" :initial-value 3 :key :device-type)
    (clingon:make-option :flag
                         :description "Fire-and-forget write: no acknowledgement, so silence means nothing"
                         :long-name "no-ack" :key :no-ack)
    (clingon:make-option :flag
                         :description "Send even when the meter is not notifying, though no reply can come back"
                         :long-name "anyway" :key :anyway)
    (clingon:make-option :integer
                         :description "Repeat the whole command list N times on the same connection"
                         :long-name "repeat" :initial-value 1 :key :repeat)
    (clingon:make-option :flag
                         :description "List the known commands and what the tested unit does with each"
                         :short-name #\l :long-name "list" :key :list)
    (clingon:make-option :flag
                         :description "Required for the resets, which cannot be undone"
                         :long-name "yes" :key :yes))))

(defun send/command ()
  (clingon:make-command
   :name "command"
   :description "send a command to the meter (Linux only; --list needs no device)"
   :usage "--list | -m MAC -c NAME [--value N] [--yes]"
   :options (send/options)
   :handler #'send/handler))

(register-subcommand (send/command))
