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

(defun scratch-directory ()
  "Returns a new, unique directory pathname under the system temporary directory."
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "bknr.hashkv-e2e-~A" (bknr.hashkv::generate-token-id))
                    (uiop:temporary-directory))))

(defmacro with-e2e-store ((directory) &body body)
  "Opens an empty store in a new directory bound to DIRECTORY, runs BODY,
and closes whichever store is open afterwards, also on error."
  `(let ((,directory (scratch-directory)))
     (declare (ignorable ,directory))
     (bknr.hashkv:close-store)
     (bknr.hashkv:open-store ,directory)
     (unwind-protect (progn ,@body)
       (bknr.hashkv:close-store))))

(defun reopen (directory)
  "Closes the store and opens it again from DIRECTORY."
  (bknr.hashkv:close-store)
  (bknr.hashkv:open-store directory))

(test full-lifecycle-through-worker
  (with-e2e-store (directory)
    (bknr.hashkv:start-worker)
    (let ((key (bknr.hashkv:submit :put "e2e value")))
      (is (string= "e2e value" (bknr.hashkv:submit :get key)))
      (is (eq t (bknr.hashkv:submit :delete key)))
      (is-false (bknr.hashkv:submit :get key)))
    (bknr.hashkv:stop-worker)))

(test entries-survive-a-store-restart
  (with-e2e-store (directory)
    (let ((key (bknr.hashkv:put-value "durable value")))
      (reopen directory)
      (is (string= "durable value" (bknr.hashkv:get-value key))))))

(test renewed-ttl-survives-a-store-restart
  (with-e2e-store (directory)
    (let ((key (bknr.hashkv:put-value "renewed" :expires-in-seconds -1)))
      (bknr.hashkv:put-value "renewed")
      (reopen directory)
      (is (string= "renewed" (bknr.hashkv:get-value key))))))

(test batch-put-then-individually-readable
  (with-e2e-store (directory)
    (let ((values '("alpha" "beta" "gamma" "delta")))
      (is (equal values (mapcar #'bknr.hashkv:get-value (bknr.hashkv:batch-put values)))))))

(test queued-entries-survive-a-store-restart
  (with-e2e-store (directory)
    (bknr.hashkv:enqueue "before restart")
    (reopen directory)
    (bknr.hashkv:enqueue "after restart")
    (is (equal "before restart" (nth-value 1 (bknr.hashkv:dequeue-claim "claimant-1"))))))

(test claims-survive-a-store-restart
  (with-e2e-store (directory)
    (bknr.hashkv:enqueue "held")
    (bknr.hashkv:dequeue-claim "claimant-1")
    (reopen directory)
    (is-false (bknr.hashkv:dequeue-claim "claimant-2"))))

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

(defun contended-put-errors ()
  "Runs 16 threads of 50 puts each and returns how many puts signalled."
  (let ((errors 0)
        (lock (bt:make-lock)))
    (run-threads 16 (lambda (thread)
                      (dotimes (round 50)
                        (handler-case (bknr.hashkv:put-value (contended-value thread round))
                          (error () (bt:with-lock-held (lock) (incf errors)))))))
    errors))

(test concurrent-mixed-puts-keep-object-table-and-key-index-consistent
  (with-e2e-store (directory)
    (is (= 0 (contended-put-errors)))
    (let ((objects (bknr.datastore:class-instances 'bknr.hashkv::kv-entry)))
      (is (= (+ 50 (* 8 50)) (length objects)))
      (is (every #'indexed-under-own-key-p objects)))))

(defun run-e2e ()
  "Runs the end-to-end suite and returns T when every test passed."
  (fiveam:run! 'bknr.hashkv-e2e-suite))
