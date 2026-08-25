;;; CLI package for the ud18 tool.
;;;
;;; All the command-line glue lives here: argument parsing, the output
;;; encoders, and one file per subcommand. The ud18/cli system in ud18.asd
;;; compiles it into a single multicall binary at bin/ud18, dispatched on
;;; argv[1] -- `ud18 monitor --mac ...`.
;;;
;;; Each subcommand file defines its handler and calls REGISTER-SUBCOMMAND at
;;; load time, so adding a tool means adding a file and an .asd entry, with
;;; no central list to keep in sync.

(defpackage #:ud18.cli
  (:use #:cl)
  (:export #:main
           #:register-subcommand
           ;; output encoders
           #:reading-text
           #:reading-jsonl
           #:reading-csv
           #:csv-header
           #:iso-timestamp
           #:hex-string
           #:hexdump
           #:undecodable-report
           #:parse-hex-bytes))
