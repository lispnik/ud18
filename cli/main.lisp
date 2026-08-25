(in-package #:ud18.cli)

;;; Subcommand dispatch.
;;;
;;; Each tool file builds a clingon command and calls REGISTER-SUBCOMMAND at
;;; load time. The top-level command is constructed fresh on every MAIN so
;;; the registry is read at startup rather than at file-load time, which
;;; means the tool files can load in any order.

(defvar *subcommands* nil)

(defun register-subcommand (cmd)
  (pushnew cmd *subcommands*
           :test (lambda (a b) (equal (clingon:command-name a) (clingon:command-name b)))))

(defun top-level/handler (cmd)
  (clingon:print-usage-and-exit cmd t))

(defun top-level-command ()
  (clingon:make-command
   :name "ud18"
   :description "Read an ATORCH UD18 USB/DC power meter over BLE."
   :long-description
   "The UD18 advertises as UD18_BLE and streams one 36-byte measurement frame
per second over GATT characteristic 0xFFE1 once you subscribe.

  ud18 scan                          find meters in range
  ud18 monitor -m CB:3B:7F:8E:75:A3  watch one live
  ud18 record  -m ... -o out.jsonl   log it to a file
  ud18 decode  --hex FF5501...       decode captured frames offline

scan, monitor, record and send need a BlueZ adapter and CAP_NET_RAW, so they
are Linux-only. decode is pure arithmetic and runs anywhere."
   :version "0.1.0"
   :authors '("Matthew Kennedy")
   :license "MIT"
   :sub-commands *subcommands*
   :handler #'top-level/handler))

(defun install-teardown ()
  "Make sure an interrupted run still hands the adapter back.

One line, because the hazard belongs to the library that creates it: the
:hci-user transport holds an HCI_CHANNEL_USER socket, and while it does,
nothing else on the machine can use that radio -- not even `hciconfig hciN
down\' as root. BLE:INSTALL-ADAPTER-TEARDOWN registers the exit hook and
turns SIGTERM and SIGHUP into an orderly exit; SBCL does not terminate on
SIGTERM by default, which is how a `timeout 60 ud18 monitor ...\' once left a
process alive holding hci0 until a SIGKILL and a manual down/up."
  (ble:install-adapter-teardown))

(defun main ()
  (install-teardown)
  (handler-case (clingon:run (top-level-command))
    ;; `ud18 decode ... | head` closes the pipe under us. That is a normal
    ;; way to use the tool, not an error worth a backtrace.
    (sb-int:broken-pipe ()
      (sb-ext:exit :code 0 :abort t))
    (sb-sys:interactive-interrupt ()
      (format *error-output* "~&Interrupted.~%")
      (sb-ext:exit :code 130))
    (ble:syscall-error (c)
      (format *error-output* "~&error: ~A~%" c)
      (when (member (ble:syscall-error-code c) '(1 13))  ; EPERM / EACCES
        (format *error-output*
                "~&hint: raw HCI and L2CAP sockets need CAP_NET_RAW + CAP_NET_ADMIN:~%~
                 ~&      sudo setcap 'cap_net_raw,cap_net_admin+eip' <path to this binary>~%"))
      (sb-ext:exit :code 1))
    (error (c)
      (format *error-output* "~&error: ~A~%" c)
      (sb-ext:exit :code 1))))
