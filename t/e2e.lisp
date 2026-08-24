;;;; t/e2e.lisp
;;;;
;;;; End-to-end guards. Unlike t/test.lisp, these exercise the system
;;;; the way a real caller would: through the worker/submit interface,
;;;; and across a close-store/open-store cycle, to catch the class of
;;;; bug unit tests miss: state that only breaks once the process
;;;; boundary or the datastore's on-disk representation is involved.

(defpackage :bknr.hashkv/e2e
  (:use :cl :fiveam)
  (:export #:run-e2e))

(in-package :bknr.hashkv/e2e)

(def-suite bknr.hashkv-e2e-suite :description "hashkv end-to-end guards")
(in-suite bknr.hashkv-e2e-suite)

(defvar *e2e-directory* #P"/tmp/bknr.hashkv-e2e-store/")

(defun fresh-e2e-store ()
  "Deletes and reopens a scratch datastore for e2e isolation. Closes
any store left open by a prior test that errored before its own
CLOSE-STORE, matching t/test.lisp's FRESH-STORE."
  (when (and (boundp 'bknr.datastore:*store*) bknr.datastore:*store*)
    (bknr.hashkv:close-store))
  (when (probe-file *e2e-directory*)
    (uiop:delete-directory-tree *e2e-directory* :validate t))
  (bknr.hashkv:open-store *e2e-directory*))

(test full-lifecycle-through-worker
  "Opens the store, starts the worker, round-trips a value entirely
through SUBMIT (never calling PUT-VALUE/GET-VALUE directly), then
tears the worker and store back down."
  (fresh-e2e-store)
  (bknr.hashkv:start-worker)
  (unwind-protect
       (let* ((key (bknr.hashkv:submit :put "e2e value"))
              (fetched (bknr.hashkv:submit :get key)))
         (is (string= "e2e value" fetched))
         (is (eq t (bknr.hashkv:submit :delete key)))
         (is (null (bknr.hashkv:submit :get key))))
    (bknr.hashkv:stop-worker)
    (bknr.hashkv:close-store)))

(test entries-survive-a-store-restart
  "Writes a value, closes the store (simulating a process restart),
reopens it at the same directory, and confirms the value is still
retrievable. The guard catches a transaction log that isn't
actually being flushed or replayed correctly."
  (fresh-e2e-store)
  (let ((key (bknr.hashkv:put-value "durable value")))
    (bknr.hashkv:close-store)
    (bknr.hashkv:open-store *e2e-directory*)
    (is (string= "durable value" (bknr.hashkv:get-value key)))
    (bknr.hashkv:close-store)))

(test batch-put-then-individually-readable
  "Batch-writes several values in parallel, then confirms each is
independently readable through the ordinary single-value path,
catching any hazard from the lparallel hashing step racing the
sequential datastore writes."
  (fresh-e2e-store)
  (let* ((values '("alpha" "beta" "gamma" "delta"))
         (keys (bknr.hashkv:batch-put values)))
    (loop for value in values
          for key in keys
          do (is (string= value (bknr.hashkv:get-value key)))))
  (bknr.hashkv:close-store))

(test queued-jobs-survive-a-store-restart
  "Enqueues a job, closes the store, reopens it, and confirms the job
is still there and still claimable in the right order. The queue
analogue of ENTRIES-SURVIVE-A-STORE-RESTART, and also a check that
the sequence counter bootstraps correctly rather than resetting to
zero and colliding with what's already persisted."
  (fresh-e2e-store)
  (bknr.hashkv:enqueue "before restart")
  (bknr.hashkv:close-store)
  (bknr.hashkv:open-store *e2e-directory*)
  (bknr.hashkv:enqueue "after restart")
  (multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "worker-1")
    (declare (ignore id))
    (is (string= "before restart" payload)))
  (bknr.hashkv:close-store))

(test stale-claim-is-reclaimed
  "Claims a job, then simulates a worker that crashed mid-job by
back-dating the claim's CLAIMED-AT, and confirms
RECLAIM-STALE-CLAIMS frees it for another worker rather than leaving
it stuck forever."
  (fresh-e2e-store)
  (let ((id (bknr.hashkv:enqueue "abandoned job")))
    (bknr.hashkv:dequeue-claim "worker-1")
    (let ((entry (bknr.hashkv::entry-with-job-id id)))
      (bknr.datastore:with-transaction ()
        (setf (bknr.hashkv::entry-claimed-at entry) (- (get-universal-time) 9999))))
    (is (= 1 (bknr.hashkv:reclaim-stale-claims :older-than-seconds 300)))
    (multiple-value-bind (reclaimed-id payload) (bknr.hashkv:dequeue-claim "worker-2")
      (is (string= id reclaimed-id))
      (is (string= "abandoned job" payload))))
  (bknr.hashkv:close-store))

(defun run-e2e ()
  "Runs the bknr.hashkv e2e suite and returns T if every guard passed."
  (fiveam:run! 'bknr.hashkv-e2e-suite))
