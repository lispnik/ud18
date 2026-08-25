;;; ud18 -- ATORCH UD18 USB/DC power meter over BLE.
;;;
;;; Split along the platform seam, which is what keeps the protocol code --
;;; and its tests -- runnable on a machine with no Bluetooth:
;;;
;;;   ud18/core -- framing, checksum, measurement decoding, the command set.
;;;                Portable; depends only on ble/core, which has no
;;;                dependencies of its own. The test suite depends only on
;;;                this, so tests need no BLE stack.
;;;   ud18/ble  -- connecting to a meter and streaming from it. Adds `ble\',
;;;                the shared BLE library, which brings HCI sockets, LE
;;;                scanning and the ATT/GATT client. Linux only.
;;;   ud18      -- umbrella loading both.
;;;   ud18/cli  -- the bin/ud18 binary; adds clingon.
;;;
;;; `ble\' and `ble/core\' come from github.com/lispnik/ble, checked out as a
;;; sibling of this tree. BLE_DIR in the Makefile points at it (../ble by
;;; default) and puts that one directory on the source registry.

(asdf:defsystem #:ud18/core
  :description "ATORCH UD18 wire protocol: framing, checksum, measurement decoding (portable)."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:ble/core)
  :components ((:module "src"
                :components ((:file "package")
                             (:file "protocol" :depends-on ("package"))
                             (:file "commands" :depends-on ("protocol")))))
  :in-order-to ((asdf:test-op (asdf:test-op #:ud18/tests))))

(asdf:defsystem #:ud18/ble
  :description "Connecting to a UD18 and streaming from it (Linux/BlueZ only)."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:ud18/core #:ble)
  :components ((:module "src"
                :components ((:file "device")))))

(asdf:defsystem #:ud18
  :description "ATORCH UD18 power meter over BLE: portable protocol core plus live BLE I/O."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:ud18/core #:ud18/ble)
  :in-order-to ((asdf:test-op (asdf:test-op #:ud18/tests))))

(asdf:defsystem #:ud18/tests
  :description "Test suite for the portable protocol core."
  :depends-on  (#:ud18/core #:fiveam)
  :components ((:module "tests"
                :serial t
                :components ((:file "package")
                             (:file "protocol-tests"))))
  :perform (asdf:test-op (op c)
             (declare (ignore op c))
             (unless (uiop:symbol-call :ud18/tests :run-tests)
               (error "ud18 test suite failed"))))

(asdf:defsystem #:ud18/cli
  :description "Command-line tool for the UD18 (multicall binary)."
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  (#:ud18 #:clingon)
  :components ((:module "cli"
                :components ((:file "package")
                             (:file "util"    :depends-on ("package"))
                             (:file "output"  :depends-on ("util"))
                             (:file "main"    :depends-on ("util"))
                             ;; One file per subcommand; each registers itself.
                             (:file "scan"    :depends-on ("main"))
                             (:file "monitor" :depends-on ("main" "output"))
                             (:file "record"  :depends-on ("main" "output"))
                             ;; decode is the only subcommand with no BLE in it
                             (:file "decode"  :depends-on ("main" "output"))
                             (:file "send"    :depends-on ("main"))
                             (:file "raw"     :depends-on ("main")))))
  :build-operation "program-op"
  :build-pathname  "bin/ud18"
  :entry-point     "ud18.cli:main")
