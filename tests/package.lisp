(defpackage #:ud18/tests
  (:use #:cl #:fiveam)
  (:export #:run-tests #:protocol))

(in-package #:ud18/tests)

(def-suite protocol :description "UD18 framing, checksum, and measurement decoding.")

(defun run-tests ()
  "Run every suite. Returns T when all checks passed -- the ASDF test-op
turns a NIL here into a non-zero exit."
  (let ((results (run 'protocol)))
    (explain! results)
    (results-status results)))
