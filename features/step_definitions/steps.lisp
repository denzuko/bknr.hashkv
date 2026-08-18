;;;; features/step_definitions/steps.lisp
;;;;
;;;; Step definitions for bknr.hashkv.feature, implemented against
;;;; sunny-side (denzuko/sunny-side), a standalone pure-Lisp Gherkin
;;;; engine extracted from this project. No Ruby, no wire protocol.
;;;; These assertions use FIVEAM:IS, the same as t/test.lisp and
;;;; t/e2e.lisp, so all three suites read consistently.

(defpackage :bknr.hashkv/bdd
  (:use :cl :sunny-side)
  (:export #:run-bdd))

(in-package :bknr.hashkv/bdd)

(defvar *last-key* nil
  "The most recent key returned by a put, for later Then steps to check against.")

(defvar *last-value* nil
  "The most recent value fetched, for later Then steps to check against.")

(defvar *key-before-repeat-put* nil
  "First key from a two-put idempotency scenario, kept for comparison.")

(Given "^a fresh bknr\\.hashkv store$" ()
  (let ((dir (merge-pathnames
              (format nil "bknr.hashkv-bdd-~A/" (get-universal-time))
              #P"/tmp/")))
    (bknr.hashkv:open-store dir)))

(When "^I put \"([^\"]*)\" into the store$" (value)
  (setf *last-key* (bknr.hashkv:put-value value)))

(When "^I put \"([^\"]*)\" into the store again$" (value)
  (setf *key-before-repeat-put* *last-key*)
  (setf *last-key* (bknr.hashkv:put-value value)))

(When "^I delete that key$" ()
  (bknr.hashkv:delete-value *last-key*))

(When "^I get a key that was never stored$" ()
  (setf *last-key* (make-string 64 :initial-element #\0)))

(Then "^I should get back a hash key$" ()
  (fiveam:is (stringp *last-key*))
  (fiveam:is (= 64 (length *last-key*))))

(Then "^getting that key should return \"([^\"]*)\"$" (expected)
  (setf *last-value* (bknr.hashkv:get-value *last-key*))
  (fiveam:is (string= expected *last-value*)))

(Then "^getting that key should return nothing$" ()
  (setf *last-value* (bknr.hashkv:get-value *last-key*))
  (fiveam:is (null *last-value*)))

(Then "^both puts should return the same key$" ()
  (fiveam:is (string= *key-before-repeat-put* *last-key*)))

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv.feature")
  :suite bknr.hashkv-gherkin-suite)

(defun run-bdd ()
  "Runs every Scenario in bknr.hashkv.feature as a FiveAM test and
returns T if every scenario passed."
  (fiveam:run! 'bknr.hashkv-gherkin-suite))
