(in-package #:ud18.cli)

;;; `ud18 scan` -- find meters in range.
;;;
;;; Active scanning, because the UD18 puts its name in the scan response
;;; rather than the advertisement. Reports are merged per address, so a
;;; device shows up once with everything learned about it.

(defun scan/handler (cmd)
  (let* ((dev  (resolve-dev (clingon:getopt cmd :dev)))
         (secs (clingon:getopt cmd :seconds))
         (all  (clingon:getopt cmd :all)))
    (format *error-output* "Scanning hci~D for ~Ds~A...~%"
            dev secs (if all "" " (UD18-like devices only; --all for everything)"))
    (force-output *error-output*)
    (let ((found (ud18:find-meters :dev dev :seconds secs :all all)))
      (if (null found)
          (progn
            (format t "~&No~:[ UD18~;~] devices seen.~%" all)
            (unless all
              (format t "~&Nothing matched on name or the 0xFFE0 service. ~
                         Re-run with --all to see every advertiser.~%")))
          (progn
            (format t "~&~17A ~7A ~5A  ~20A ~A~%"
                    "ADDRESS" "TYPE" "RSSI" "NAME" "SERVICES")
            (dolist (d found)
              (format t "~17A ~7A ~5@A  ~20A ~{~4,'0X~^ ~}~%"
                      (ble:format-mac (ble:discovered-address d))
                      (addr-type-label (ble:discovered-addr-type d))
                      (or (ble:discovered-rssi d) "?")
                      (or (ble:discovered-name d) "-")
                      (ble:discovered-service-uuids d)))
            (format t "~%~D device~:P. Connect with: ud18 monitor -m ~A~%"
                    (length found)
                    (ble:format-mac (ble:discovered-address (first found)))))))
    (force-output)))

(defun scan/options ()
  (list
   (clingon:make-option :integer
                        :description "HCI adapter index (default: lowest present; try each with `ud18 scan`)"
                        :short-name #\d :long-name "dev" :key :dev)
   (clingon:make-option :integer
                        :description "Scan duration in seconds"
                        :short-name #\s :long-name "seconds" :initial-value 8 :key :seconds)
   (clingon:make-option :flag
                        :description "List every advertiser, not just UD18-like ones"
                        :long-name "all" :key :all)))

(defun scan/command ()
  (clingon:make-command
   :name "scan"
   :description "scan for UD18 meters in range (Linux only)"
   :usage "[--dev N] [--seconds N] [--all]"
   :options (scan/options)
   :handler #'scan/handler))

(register-subcommand (scan/command))
