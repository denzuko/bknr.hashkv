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

(Given! "^a fresh bknr\\.hashkv store$" ()
  (when (and (boundp 'bknr.datastore:*store*) bknr.datastore:*store*)
    (bknr.hashkv:close-store))
  (let ((dir (merge-pathnames
              (format nil "bknr.hashkv-bdd-~(~36R~)-~(~36R~)/"
                      (get-universal-time) (random most-positive-fixnum))
              #P"/tmp/")))
    (bknr.hashkv:open-store dir)))

(When! "^I put \"([^\"]*)\" into the store$" (value)
  (setf *last-key* (bknr.hashkv:put-value value)))

(When! "^I put \"([^\"]*)\" into the store again$" (value)
  (setf *key-before-repeat-put* *last-key*)
  (setf *last-key* (bknr.hashkv:put-value value)))

(When! "^I delete that key$" ()
  (bknr.hashkv:delete-value *last-key*))

(When! "^I get a key that was never stored$" ()
  (setf *last-key* (make-string 64 :initial-element #\0)))

(Then! "^I should get back a hash key$" ()
  (fiveam:is (stringp *last-key*))
  (fiveam:is (= 64 (length *last-key*))))

(Then! "^getting that key should return \"([^\"]*)\"$" (expected)
  (setf *last-value* (bknr.hashkv:get-value *last-key*))
  (fiveam:is (string= expected *last-value*)))

(Then! "^getting that key should return nothing$" ()
  (setf *last-value* (bknr.hashkv:get-value *last-key*))
  (fiveam:is (null *last-value*)))

(Then! "^both puts should return the same key$" ()
  (fiveam:is (string= *key-before-repeat-put* *last-key*)))

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv.feature")
  :suite bknr.hashkv-gherkin-suite)

;;; --- Queue steps -------------------------------------------------------
;;;
;;; Written against the renamed queue API (ACK-CLAIM/RELEASE-CLAIM,
;;; not ACK-JOB/RELEASE-JOB) before that rename existed in
;;; src/store.lisp. This is the intended red phase: these steps do
;;; not compile against the pre-rename source, and only pass once
;;; the source provides the renamed functions.

(defvar *last-token* nil
  "The most recent token id returned by ENQUEUE, for later steps to
check against.")

(defvar *token-before-repeat-enqueue* nil
  "First token id from a two-enqueue distinctness scenario, kept for
comparison.")

(defvar *claimed-token* nil
  "The token id most recently returned by a claim, for later steps to
acknowledge or release.")

(defvar *claimed-payload* nil
  "The payload most recently returned by a claim, or NIL if nothing
was claimable.")

(When! "^I queue \"([^\"]*)\" onto the queue$" (payload)
  (setf *last-token* (bknr.hashkv:enqueue payload)))

(When! "^I queue \"([^\"]*)\" onto the queue again$" (payload)
  (setf *token-before-repeat-enqueue* *last-token*)
  (setf *last-token* (bknr.hashkv:enqueue payload)))

(When! "^a claimant claims the next entry$" ()
  (multiple-value-bind (token payload) (bknr.hashkv:dequeue-claim "claimant-1")
    (setf *claimed-token* token
          *claimed-payload* payload)))

(When! "^another claimant claims the next entry$" ()
  (multiple-value-bind (token payload) (bknr.hashkv:dequeue-claim "claimant-2")
    (setf *claimed-token* token
          *claimed-payload* payload)))

(When! "^the claimant acknowledges that claim$" ()
  (bknr.hashkv:ack-claim *claimed-token*))

(When! "^the claimant releases that claim$" ()
  (bknr.hashkv:release-claim *claimed-token*))

(Then! "^I should get back a token id$" ()
  (fiveam:is (stringp *last-token*)))

(Then! "^both queued entries should have different token ids$" ()
  (fiveam:is (not (string= *token-before-repeat-enqueue* *last-token*))))

(Then! "^the claimed payload should be \"([^\"]*)\"$" (expected)
  (fiveam:is (string= expected *claimed-payload*)))

(Then! "^the second claim should find nothing$" ()
  (fiveam:is (null *claimed-token*)))

(Then! "^a claimant claiming the next entry should find nothing$" ()
  (multiple-value-bind (token payload) (bknr.hashkv:dequeue-claim "claimant-3")
    (declare (ignore payload))
    (fiveam:is (null token))))

(Then! "^a claimant claiming the next entry should find \"([^\"]*)\"$" (expected)
  (multiple-value-bind (token payload) (bknr.hashkv:dequeue-claim "claimant-3")
    (declare (ignore token))
    (fiveam:is (string= expected payload))))

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv-queue.feature")
  :suite bknr.hashkv-queue-gherkin-suite)

(defun run-bdd ()
  "Runs every Scenario in bknr.hashkv.feature and
bknr.hashkv-queue.feature as FiveAM tests, and returns T if every
scenario in both passed."
  (let ((kv-result (fiveam:run! 'bknr.hashkv-gherkin-suite))
        (queue-result (fiveam:run! 'bknr.hashkv-queue-gherkin-suite)))
    (and kv-result queue-result)))
