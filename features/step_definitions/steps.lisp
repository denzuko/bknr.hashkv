;;;; features/step_definitions/steps.lisp
;;;;
;;;; Step definitions for the key/value and queue features, run as
;;;; FiveAM tests through sunny-side.

(defpackage :bknr.hashkv/bdd
  (:use :cl :sunny-side)
  (:import-from :fiveam #:is #:is-true #:is-false)
  (:export #:run-bdd))

(in-package :bknr.hashkv/bdd)

(defvar *store-dir* nil "Scratch directory of the store opened by the Background step.")
(defvar *last-key* nil "Key returned by the most recent put.")
(defvar *previous-key* nil "Key returned by the put before the most recent one.")
(defvar *list-keys* nil "Keys returned by the printer-settings scenario, newest first.")
(defvar *signalled* nil "Condition signalled by the most recent put, or NIL.")
(defvar *thread-keys* nil "Keys returned by the concurrent put threads.")
(defvar *thread-errors* nil "Conditions signalled inside the concurrent put threads.")
(defvar *last-token* nil "Token id returned by the most recent enqueue.")
(defvar *previous-token* nil "Token id returned by the enqueue before the most recent one.")
(defvar *claimed-token* nil "Token id returned by the most recent claim.")
(defvar *claimed-payload* nil "Payload returned by the most recent claim.")
(defvar *ack-result* nil "Return value of the most recent acknowledgement.")
(defvar *seeded-state* nil "Random state copied before the first seeded enqueue.")
(defvar *claimed-tokens* nil "Every token id claimed by the concurrent claimants.")
(defvar *queued-tokens* nil "Every token id queued by the bulk enqueue step.")

(defun scratch-directory ()
  "Returns a new, unique directory pathname under the system temporary directory."
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "bknr.hashkv-bdd-~A" (bknr.hashkv::generate-token-id))
                    (uiop:temporary-directory))))

(defun capture-signal (thunk)
  "Calls THUNK and records any error it signals in *SIGNALLED*."
  (setf *signalled* nil)
  (handler-case (funcall thunk)
    (error (condition) (setf *signalled* condition) nil)))

(defun run-threads (count function)
  "Runs FUNCTION on COUNT threads released together, and waits for all of them."
  (let* ((gate (bt:make-semaphore))
         (threads (loop repeat count
                        collect (bt:make-thread (lambda () (bt:wait-on-semaphore gate) (funcall function))))))
    (bt:signal-semaphore gate :count count)
    (mapc #'bt:join-thread threads)))

(defun claim (claimant)
  "Claims the next entry for CLAIMANT and records the token id and payload."
  (multiple-value-setq (*claimed-token* *claimed-payload*) (bknr.hashkv:dequeue-claim claimant)))

;;; --- Store lifecycle ---------------------------------------------------

(Given! "^a fresh bknr\\.hashkv store$" ()
  (bknr.hashkv:close-store)
  (setf *store-dir* (scratch-directory))
  (bknr.hashkv:open-store *store-dir*))

(When! "^the store is closed and reopened$" ()
  (bknr.hashkv:close-store)
  (bknr.hashkv:open-store *store-dir*))

;;; --- Key/value steps ---------------------------------------------------

(When! "^I put \"([^\"]*)\" into the store$" (value)
  (setf *previous-key* *last-key*
        *last-key* (bknr.hashkv:put-value value)))

(When! "^I put \"([^\"]*)\" into the store again$" (value)
  (setf *previous-key* *last-key*
        *last-key* (bknr.hashkv:put-value value)))

(When! "^I put \"([^\"]*)\" into the store with a TTL of (-?\\d+) seconds$" (value seconds)
  (setf *last-key* (bknr.hashkv:put-value value :expires-in-seconds (parse-integer seconds))))

(When! "^I put the list 1 2 (\\d+) into the store while print length is 2$" (last)
  (let ((*print-length* 2))
    (push (bknr.hashkv:put-value (list 1 2 (parse-integer last))) *list-keys*)))

(When! "^I put \"([^\"]*)\" under the key of \"([^\"]*)\"$" (value genuine)
  (let ((key (bknr.hashkv:put-value genuine)))
    (capture-signal (lambda () (bknr.hashkv:put-keyed key value)))))

(When! "^I put an unreadable object into the store$" ()
  (capture-signal (lambda () (bknr.hashkv:put-value (make-instance 'standard-object)))))

(When! "^(\\d+) threads put \"([^\"]*)\" into the store at once$" (count value)
  (let ((lock (bt:make-lock)))
    (setf *thread-keys* nil *thread-errors* nil)
    (run-threads (parse-integer count)
                 (lambda ()
                   (handler-case (let ((key (bknr.hashkv:put-value value)))
                                   (bt:with-lock-held (lock) (push key *thread-keys*)))
                     (error (condition) (bt:with-lock-held (lock) (push condition *thread-errors*))))))))

(When! "^I delete that key$" ()
  (bknr.hashkv:delete-value *last-key*))

(When! "^I get a key that was never stored$" ()
  (setf *last-key* (make-string 64 :initial-element #\0)))

(Then! "^I should get back a hash key$" ()
  (is (stringp *last-key*))
  (is (= 64 (length *last-key*))))

(Then! "^getting that key should return \"([^\"]*)\"$" (expected)
  (is (equal expected (bknr.hashkv:get-value *last-key*))))

(Then! "^getting that key should return nothing$" ()
  (is-false (bknr.hashkv:get-value *last-key*)))

(Then! "^both puts should return the same key$" ()
  (is (string= *previous-key* *last-key*)))

(Then! "^the two list keys should differ$" ()
  (is-false (string= (first *list-keys*) (second *list-keys*))))

(Then! "^the put should signal a reserved key error$" ()
  (is (typep *signalled* 'bknr.hashkv:reserved-key-error)))

(Then! "^the put should signal a print error$" ()
  (is (typep *signalled* 'print-not-readable)))

(Then! "^no put should have signalled an error$" ()
  (is-false *thread-errors*))

(Then! "^every put should have returned the same key$" ()
  (is (= 1 (length (remove-duplicates *thread-keys* :test #'string=)))))

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv.feature")
  :suite bknr.hashkv-gherkin-suite)

;;; --- Queue steps -------------------------------------------------------

(When! "^I queue \"([^\"]*)\" onto the queue$" (payload)
  (setf *previous-token* *last-token*
        *last-token* (bknr.hashkv:enqueue payload)))

(When! "^I queue \"([^\"]*)\" onto the queue again$" (payload)
  (setf *previous-token* *last-token*
        *last-token* (bknr.hashkv:enqueue payload)))

(When! "^I queue \"([^\"]*)\" onto the queue from a freshly seeded random state$" (payload)
  (setf *seeded-state* (make-random-state nil))
  (let ((*random-state* (make-random-state *seeded-state*)))
    (setf *last-token* (bknr.hashkv:enqueue payload))))

(When! "^I queue \"([^\"]*)\" onto the queue from the same freshly seeded random state$" (payload)
  (let ((*random-state* (make-random-state *seeded-state*)))
    (setf *previous-token* *last-token*
          *last-token* (bknr.hashkv:enqueue payload))))

(When! "^I queue (\\d+) entries onto the queue$" (count)
  (setf *queued-tokens* (loop for i below (parse-integer count) collect (bknr.hashkv:enqueue i))))

(When! "^(\\d+) claimants drain the queue at once$" (count)
  (let ((lock (bt:make-lock)))
    (setf *claimed-tokens* nil)
    (run-threads (parse-integer count)
                 (lambda ()
                   (loop for token = (bknr.hashkv:dequeue-claim (bknr.hashkv::generate-token-id))
                         while token
                         do (bt:with-lock-held (lock) (push token *claimed-tokens*)))))))

(When! "^a claimant claims the next entry$" ()
  (claim "claimant-1"))

(When! "^another claimant claims the next entry$" ()
  (claim "claimant-2"))

(When! "^the claimant acknowledges that claim$" ()
  (setf *ack-result* (bknr.hashkv:ack-claim *claimed-token*)))

(When! "^the claimant acknowledges the token id \"([^\"]*)\"$" (token)
  (setf *ack-result* (bknr.hashkv:ack-claim token)))

(When! "^the claimant releases that claim$" ()
  (bknr.hashkv:release-claim *claimed-token*))

(Then! "^I should get back a token id$" ()
  (is (stringp *last-token*)))

(Then! "^both queued entries should have different token ids$" ()
  (is-false (string= *previous-token* *last-token*)))

(Then! "^the claimed payload should be \"([^\"]*)\"$" (expected)
  (is (equal expected *claimed-payload*)))

(Then! "^the second claim should find nothing$" ()
  (is-false *claimed-token*))

(Then! "^the acknowledgement should be refused$" ()
  (is-false *ack-result*))

(Then! "^every entry should have been claimed exactly once$" ()
  (is (= (length *queued-tokens*) (length *claimed-tokens*)))
  (is (null (set-exclusive-or *queued-tokens* *claimed-tokens* :test #'string=))))

(Then! "^a claimant claiming the next entry should find nothing$" ()
  (claim "claimant-3")
  (is-false *claimed-token*))

(Then! "^a claimant claiming the next entry should find \"([^\"]*)\"$" (expected)
  (claim "claimant-3")
  (is (equal expected *claimed-payload*)))

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv-queue.feature")
  :suite bknr.hashkv-queue-gherkin-suite)

(defun run-bdd ()
  "Runs both feature suites, all of them even after a failure, and returns T
when every scenario passed."
  (notany #'null (mapcar #'fiveam:run! '(bknr.hashkv-gherkin-suite bknr.hashkv-queue-gherkin-suite))))
