;;;; t/e2e.lisp
;;;;
;;;; End-to-end suite: drives the API through the worker and across a
;;;; close and reopen of the same store directory.

(defpackage :bknr.hashkv/e2e
  (:use :cl :fiveam)
  (:export #:run-e2e))

(in-package :bknr.hashkv/e2e)

(def-suite bknr.hashkv-e2e-suite :description "bknr.hashkv end-to-end tests")
(in-suite bknr.hashkv-e2e-suite)

(defvar *e2e-directory* nil "Directory of the store opened by FRESH-E2E-STORE.")

(defun fresh-e2e-store ()
  "Closes any open store and opens an empty one in a new temporary directory."
  (bknr.hashkv:close-store)
  (setf *e2e-directory*
        (uiop:ensure-directory-pathname
         (merge-pathnames (format nil "bknr.hashkv-e2e-~A" (bknr.hashkv::generate-token-id))
                          (uiop:temporary-directory))))
  (bknr.hashkv:open-store *e2e-directory*))

(defun reopen ()
  "Closes the store and opens it again from the same directory."
  (bknr.hashkv:close-store)
  (bknr.hashkv:open-store *e2e-directory*))

(test full-lifecycle-through-worker
  (fresh-e2e-store)
  (bknr.hashkv:start-worker)
  (unwind-protect
       (let ((key (bknr.hashkv:submit :put "e2e value")))
         (is (string= "e2e value" (bknr.hashkv:submit :get key)))
         (is (eq t (bknr.hashkv:submit :delete key)))
         (is-false (bknr.hashkv:submit :get key)))
    (bknr.hashkv:stop-worker)
    (bknr.hashkv:close-store)))

(test entries-survive-a-store-restart
  (fresh-e2e-store)
  (let ((key (bknr.hashkv:put-value "durable value")))
    (reopen)
    (is (string= "durable value" (bknr.hashkv:get-value key))))
  (bknr.hashkv:close-store))

(test renewed-ttl-survives-a-store-restart
  (fresh-e2e-store)
  (let ((key (bknr.hashkv:put-value "renewed" :expires-in-seconds -1)))
    (bknr.hashkv:put-value "renewed")
    (reopen)
    (is (string= "renewed" (bknr.hashkv:get-value key))))
  (bknr.hashkv:close-store))

(test batch-put-then-individually-readable
  (fresh-e2e-store)
  (let ((values '("alpha" "beta" "gamma" "delta")))
    (is (equal values (mapcar #'bknr.hashkv:get-value (bknr.hashkv:batch-put values)))))
  (bknr.hashkv:close-store))

(test queued-entries-survive-a-store-restart
  (fresh-e2e-store)
  (bknr.hashkv:enqueue "before restart")
  (reopen)
  (bknr.hashkv:enqueue "after restart")
  (is (equal "before restart" (nth-value 1 (bknr.hashkv:dequeue-claim "claimant-1"))))
  (bknr.hashkv:close-store))

(test claims-survive-a-store-restart
  (fresh-e2e-store)
  (bknr.hashkv:enqueue "held")
  (bknr.hashkv:dequeue-claim "claimant-1")
  (reopen)
  (is-false (bknr.hashkv:dequeue-claim "claimant-2"))
  (bknr.hashkv:close-store))

(defun run-threads (count function)
  "Runs FUNCTION with each index below COUNT on its own thread, releases the
threads together, and waits for all of them."
  (let* ((gate (bt:make-semaphore))
         (threads (loop for n below count
                        collect (let ((n n))
                                  (bt:make-thread (lambda () (bt:wait-on-semaphore gate) (funcall function n)))))))
    (bt:signal-semaphore gate :count count)
    (mapc #'bt:join-thread threads)))

(defun contended-value (thread round)
  "Returns the value THREAD writes in ROUND: even threads share one value
per round, odd threads write their own."
  (cond ((evenp thread) (format nil "shared-~D" round))
        (t (format nil "~D-~D" thread round))))

(defun indexed-under-own-key-p (entry)
  "True when the key index maps ENTRY's key back to ENTRY itself."
  (eq entry (bknr.hashkv::entry-with-key (bknr.hashkv::entry-key entry))))

(test concurrent-mixed-puts-keep-object-table-and-key-index-consistent
  (fresh-e2e-store)
  (let ((errors 0)
        (lock (bt:make-lock)))
    (run-threads 16 (lambda (thread)
                      (dotimes (round 50)
                        (handler-case (bknr.hashkv:put-value (contended-value thread round))
                          (error () (bt:with-lock-held (lock) (incf errors)))))))
    (let ((objects (bknr.datastore:class-instances 'bknr.hashkv::kv-entry)))
      (is (= 0 errors))
      (is (= (+ 50 (* 8 50)) (length objects)))
      (is (every #'indexed-under-own-key-p objects))))
  (bknr.hashkv:close-store))

(defun run-e2e ()
  "Runs the end-to-end suite and returns T when every test passed."
  (fiveam:run! 'bknr.hashkv-e2e-suite))
