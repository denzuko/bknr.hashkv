;;;; t/test.lisp

(defpackage :bknr.hashkv/tests
  (:use :cl :fiveam)
  (:export #:run-tests))

(in-package :bknr.hashkv/tests)

(def-suite bknr.hashkv-suite :description "hashkv store tests")
(in-suite bknr.hashkv-suite)

(defvar *test-directory* #P"/tmp/bknr.hashkv-test-store/")

(defun fresh-store ()
  "Deletes and reopens a scratch datastore, so each test starts
isolated. Closes any store left open by a prior test that errored
before reaching its own CLOSE-STORE, so one failure does not cascade
into STORE-ALREADY-OPEN on every test after it."
  (when (and (boundp 'bknr.datastore:*store*) bknr.datastore:*store*)
    (bknr.hashkv:close-store))
  (when (probe-file *test-directory*)
    (uiop:delete-directory-tree *test-directory* :validate t))
  (bknr.hashkv:open-store *test-directory*))

;;; --- KV: content-addressed --------------------------------------------

(test put-and-get-round-trip
  (fresh-store)
  (let ((key (bknr.hashkv:put-value "hello world")))
    (is (string= "hello world" (bknr.hashkv:get-value key))))
  (bknr.hashkv:close-store))

(test put-is-idempotent-by-hash
  (fresh-store)
  (let ((key-a (bknr.hashkv:put-value 42))
        (key-b (bknr.hashkv:put-value 42)))
    (is (string= key-a key-b)))
  (bknr.hashkv:close-store))

(test delete-removes-entry
  (fresh-store)
  (let ((key (bknr.hashkv:put-value :some-value)))
    (is (eq t (bknr.hashkv:delete-value key)))
    (is (null (bknr.hashkv:get-value key))))
  (bknr.hashkv:close-store))

(test get-on-missing-key-returns-nil
  (fresh-store)
  (is (null (bknr.hashkv:get-value "0000000000000000000000000000000000000000000000000000000000000000")))
  (bknr.hashkv:close-store))

(test batch-put-returns-matching-order
  (fresh-store)
  (let ((keys (bknr.hashkv:batch-put '(1 2 3))))
    (is (= 3 (length keys)))
    (is (string= (first keys) (bknr.hashkv:put-value 1))))
  (bknr.hashkv:close-store))

(test submit-round-trips-through-worker
  (fresh-store)
  (bknr.hashkv:start-worker)
  (let* ((key (bknr.hashkv:submit :put "queued"))
         (value (bknr.hashkv:submit :get key)))
    (is (string= "queued" value)))
  (bknr.hashkv:stop-worker)
  (bknr.hashkv:close-store))

(test start-worker-is-idempotent
  "A second START-WORKER call used to orphan the first worker task
permanently, since STOP-WORKER only ever signals whichever task
*WORKER-THREAD* currently points at."
  (fresh-store)
  (bknr.hashkv:start-worker)
  (let ((first-task bknr.hashkv::*worker-thread*))
    (bknr.hashkv:start-worker)
    (is (eq first-task bknr.hashkv::*worker-thread*)))
  (bknr.hashkv:stop-worker)
  (bknr.hashkv:close-store))

;;; --- KV: caller-keyed ---------------------------------------------------

(test put-keyed-uses-caller-supplied-key
  (fresh-store)
  (bknr.hashkv:put-keyed "session:abc" "user-42")
  (is (string= "user-42" (bknr.hashkv:get-value "session:abc")))
  (bknr.hashkv:close-store))

(test put-keyed-overwrites-existing-value
  (fresh-store)
  (bknr.hashkv:put-keyed "counter:hits" 1)
  (bknr.hashkv:put-keyed "counter:hits" 2)
  (is (= 2 (bknr.hashkv:get-value "counter:hits")))
  (bknr.hashkv:close-store))

;;; --- TTL ----------------------------------------------------------------

(test expired-kv-entry-reads-as-absent
  (fresh-store)
  (let ((key (bknr.hashkv:put-keyed "temp:token" "abc" :expires-in-seconds -1)))
    (is (null (bknr.hashkv:get-value key))))
  (bknr.hashkv:close-store))

(test unexpired-kv-entry-still-readable
  (fresh-store)
  (let ((key (bknr.hashkv:put-keyed "temp:token" "abc" :expires-in-seconds 3600)))
    (is (string= "abc" (bknr.hashkv:get-value key))))
  (bknr.hashkv:close-store))

;;; --- Queue ----------------------------------------------------------------

(test identical-payloads-get-distinct-entries
  (fresh-store)
  (let ((id-a (bknr.hashkv:enqueue "same payload"))
        (id-b (bknr.hashkv:enqueue "same payload")))
    (is (not (string= id-a id-b))))
  (bknr.hashkv:close-store))

(test dequeue-claim-returns-oldest-first
  (fresh-store)
  (bknr.hashkv:enqueue "first")
  (bknr.hashkv:enqueue "second")
  (multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "claimant-1")
    (declare (ignore id))
    (is (string= "first" payload)))
  (bknr.hashkv:close-store))

(test claimed-entry-is-not-claimable-again
  (fresh-store)
  (bknr.hashkv:enqueue "only entry")
  (bknr.hashkv:dequeue-claim "claimant-1")
  (is (null (bknr.hashkv:dequeue-claim "claimant-2")))
  (bknr.hashkv:close-store))

(test ack-removes-entry-from-queue
  (fresh-store)
  (bknr.hashkv:enqueue "to finish")
  (multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "claimant-1")
    (declare (ignore payload))
    (is (eq t (bknr.hashkv:ack-claim id))))
  (is (null (bknr.hashkv:dequeue-claim "claimant-2")))
  (bknr.hashkv:close-store))

(test release-makes-entry-claimable-again
  (fresh-store)
  (bknr.hashkv:enqueue "retry me")
  (multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "claimant-1")
    (declare (ignore payload))
    (bknr.hashkv:release-claim id))
  (multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "claimant-2")
    (declare (ignore id))
    (is (string= "retry me" payload)))
  (bknr.hashkv:close-store))

(defun run-tests ()
  "Runs the bknr.hashkv test suite and returns T if every test passed."
  (fiveam:run! 'bknr.hashkv-suite))
