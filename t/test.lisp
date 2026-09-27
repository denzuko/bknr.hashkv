;;;; t/test.lisp
;;;;
;;;; Unit suite: one behaviour per test, called directly against the API.

(defpackage :bknr.hashkv/tests
  (:use :cl :fiveam)
  (:export #:run-tests))

(in-package :bknr.hashkv/tests)

(def-suite bknr.hashkv-suite :description "bknr.hashkv unit tests")
(in-suite bknr.hashkv-suite)

(defun fresh-store ()
  "Closes any open store and opens an empty one in a new temporary directory."
  (bknr.hashkv:close-store)
  (bknr.hashkv:open-store
   (uiop:ensure-directory-pathname
    (merge-pathnames (format nil "bknr.hashkv-test-~A" (bknr.hashkv::generate-token-id))
                     (uiop:temporary-directory)))))

(defmacro with-fresh-store (&body body)
  "Runs BODY against a fresh store and closes it afterwards, also on error."
  `(progn (fresh-store)
          (unwind-protect (progn ,@body)
            (bknr.hashkv:close-store))))

(defmacro with-worker (&body body)
  "Runs BODY with the open store's worker started, and stops it afterwards."
  `(progn (bknr.hashkv:start-worker)
          (unwind-protect (progn ,@body)
            (bknr.hashkv:stop-worker))))

(defun backdate-claim (token-id seconds)
  "Moves the claim time of entry TOKEN-ID SECONDS into the past."
  (let ((entry (bknr.hashkv::entry-with-token-id token-id)))
    (bknr.datastore:with-transaction ()
      (setf (bknr.hashkv::entry-claimed-at entry) (- (get-universal-time) seconds)))))

;;; --- Content-addressed KV ---------------------------------------------

(test put-and-get-round-trip
  (with-fresh-store
    (let ((key (bknr.hashkv:put-value "hello world")))
      (is (string= "hello world" (bknr.hashkv:get-value key))))))

(test put-is-idempotent-by-hash
  (with-fresh-store
    (is (string= (bknr.hashkv:put-value 42) (bknr.hashkv:put-value 42)))))

(test delete-removes-entry
  (with-fresh-store
    (let ((key (bknr.hashkv:put-value :some-value)))
      (is (eq t (bknr.hashkv:delete-value key)))
      (is-false (bknr.hashkv:get-value key)))))

(test delete-of-missing-key-returns-nil
  (with-fresh-store
    (is-false (bknr.hashkv:delete-value "absent"))))

(test get-on-missing-key-returns-nil
  (with-fresh-store
    (is-false (bknr.hashkv:get-value (make-string 64 :initial-element #\0)))))

(test hash-ignores-current-package
  (let ((expected (bknr.hashkv::hash-value :token)))
    (let ((*package* (find-package :bknr.hashkv)))
      (is (string= expected (bknr.hashkv::hash-value :token))))))

(test hash-ignores-print-base
  (is (string= (bknr.hashkv::hash-value 255)
               (let ((*print-base* 16) (*print-radix* t)) (bknr.hashkv::hash-value 255)))))

(test hash-of-unreadable-value-signals
  (signals print-not-readable (bknr.hashkv::hash-value (make-instance 'standard-object))))

(test content-key-p-accepts-only-lowercase-hex-of-length-64
  (is-true (bknr.hashkv::content-key-p (bknr.hashkv::hash-value "x")))
  (is-false (bknr.hashkv::content-key-p (string-upcase (bknr.hashkv::hash-value "x"))))
  (is-false (bknr.hashkv::content-key-p "abc")))

(test batch-put-returns-matching-order
  (with-fresh-store
    (let ((keys (bknr.hashkv:batch-put '(1 2 3))))
      (is (equal keys (mapcar #'bknr.hashkv:put-value '(1 2 3)))))))

(test batch-put-applies-ttl
  (with-fresh-store
    (let ((keys (bknr.hashkv:batch-put '(1 2) :expires-in-seconds -1)))
      (is (every #'null (mapcar #'bknr.hashkv:get-value keys))))))

(test batch-put-uses-the-callers-kernel
  (let ((lparallel:*kernel* (lparallel:make-kernel 2 :name "caller")))
    (unwind-protect
         (let ((seen (bknr.hashkv::call-with-kernel (lambda () lparallel:*kernel*))))
           (is (eq lparallel:*kernel* seen)))
      (lparallel:end-kernel :wait t))))

(test batch-put-ends-the-kernel-it-creates
  (let ((lparallel:*kernel* nil))
    (let ((created (bknr.hashkv::call-with-kernel (lambda () lparallel:*kernel*))))
      (is-true created)
      (is-false lparallel:*kernel*)
      (let ((lparallel:*kernel* created))
        (signals error (lparallel:pmap 'list #'identity '(1)))))))

;;; --- Caller-keyed KV ------------------------------------------------------

(test put-keyed-uses-caller-supplied-key
  (with-fresh-store
    (bknr.hashkv:put-keyed "session:abc" "user-42")
    (is (string= "user-42" (bknr.hashkv:get-value "session:abc")))))

(test put-keyed-overwrites-existing-value
  (with-fresh-store
    (bknr.hashkv:put-keyed "counter:hits" 1)
    (bknr.hashkv:put-keyed "counter:hits" 2)
    (is (= 2 (bknr.hashkv:get-value "counter:hits")))))

(test put-keyed-rejects-content-hash-keys
  (with-fresh-store
    (signals bknr.hashkv:reserved-key-error
      (bknr.hashkv:put-keyed (bknr.hashkv:put-value "genuine") "forged"))))

(test put-keyed-rejects-non-string-keys
  (with-fresh-store
    (signals type-error (bknr.hashkv:put-keyed 42 "value"))))

;;; --- TTL ----------------------------------------------------------------

(test expired-kv-entry-reads-as-absent
  (with-fresh-store
    (let ((key (bknr.hashkv:put-keyed "temp:token" "abc" :expires-in-seconds -1)))
      (is-false (bknr.hashkv:get-value key)))))

(test unexpired-kv-entry-still-readable
  (with-fresh-store
    (let ((key (bknr.hashkv:put-keyed "temp:token" "abc" :expires-in-seconds 3600)))
      (is (string= "abc" (bknr.hashkv:get-value key))))))

(test expire-key-keeps-an-entry-renewed-before-it-ran
  (with-fresh-store
    (bknr.hashkv:put-keyed "renewed" "v" :expires-in-seconds 3600)
    (bknr.hashkv::expire-key "renewed")
    (is (string= "v" (bknr.hashkv:get-value "renewed")))))

(test expire-key-on-missing-key-returns-nil
  (with-fresh-store
    (is-false (bknr.hashkv::expire-key "absent"))))

(test sweep-expired-counts-removed-entries
  (with-fresh-store
    (bknr.hashkv:put-keyed "gone" 1 :expires-in-seconds -1)
    (bknr.hashkv:enqueue "gone" :expires-in-seconds -1)
    (bknr.hashkv:put-keyed "kept" 1)
    (is (= 2 (bknr.hashkv:sweep-expired)))))

;;; --- Queue ----------------------------------------------------------------

(test token-ids-are-32-hex-digits
  (is (= 32 (length (bknr.hashkv::generate-token-id)))))

(test dequeue-claim-skips-expired-entries
  (with-fresh-store
    (bknr.hashkv:enqueue "stale" :expires-in-seconds -1)
    (bknr.hashkv:enqueue "live")
    (is (equal "live" (nth-value 1 (bknr.hashkv:dequeue-claim "c1"))))))

(test dequeue-claim-leaves-the-index-list-intact
  (with-fresh-store
    (dotimes (i 5) (bknr.hashkv:enqueue i))
    (bknr.hashkv:dequeue-claim "c1")
    (is (= 5 (length (bknr.hashkv::queue-entries))))))

(test oldest-claimable-orders-by-object-id-not-list-order
  (with-fresh-store
    (bknr.hashkv:enqueue "first")
    (bknr.hashkv:enqueue "second")
    (let ((oldest (bknr.hashkv::oldest-claimable (reverse (bknr.hashkv::queue-entries)) (get-universal-time))))
      (is (equal "first" (bknr.hashkv::entry-payload oldest))))))

(test release-of-unknown-token-returns-nil
  (with-fresh-store
    (is-false (bknr.hashkv:release-claim "no-such-token"))))

(test reclaim-leaves-fresh-claims-alone
  (with-fresh-store
    (bknr.hashkv:enqueue "busy")
    (bknr.hashkv:dequeue-claim "c1")
    (is (= 0 (bknr.hashkv:reclaim-stale-claims :older-than-seconds 300)))))

(test reclaim-clears-stale-claims
  (with-fresh-store
    (let ((token (bknr.hashkv:enqueue "abandoned")))
      (bknr.hashkv:dequeue-claim "c1")
      (backdate-claim token 9999)
      (is (= 1 (bknr.hashkv:reclaim-stale-claims :older-than-seconds 300)))
      (is (string= token (bknr.hashkv:dequeue-claim "c2"))))))

;;; --- Worker ---------------------------------------------------------------

(test submit-round-trips-through-worker
  (with-fresh-store
    (with-worker
      (is (string= "queued" (bknr.hashkv:submit :get (bknr.hashkv:submit :put "queued")))))))

(test start-worker-is-idempotent
  (with-fresh-store
    (with-worker
      (is (eq (bknr.hashkv:start-worker) (bknr.hashkv:start-worker))))))

(test start-worker-without-a-store-signals
  (bknr.hashkv:close-store)
  (signals error (bknr.hashkv:start-worker)))

(test submit-accepts-an-explicit-worker
  (with-fresh-store
    (let ((worker (bknr.hashkv:start-worker)))
      (unwind-protect
           (is (string= "a" (bknr.hashkv:submit :get (bknr.hashkv:submit :put "a" worker) worker)))
        (bknr.hashkv:stop-worker worker)))))

(test stop-worker-is-idempotent
  (with-fresh-store
    (bknr.hashkv:start-worker)
    (bknr.hashkv:stop-worker)
    (bknr.hashkv:stop-worker)
    (is-false (bknr.hashkv:worker-running-p))))

(test stop-worker-without-a-worker-does-nothing
  (with-fresh-store
    (is-false (bknr.hashkv:stop-worker))))

(test concurrent-stop-worker-calls-all-return
  (with-fresh-store
    (let* ((worker (bknr.hashkv:start-worker))
           (threads (loop repeat 8 collect (bt:make-thread (lambda () (bknr.hashkv:stop-worker worker))))))
      (mapc #'bt:join-thread threads)
      (is-false (bknr.hashkv:worker-running-p worker)))))

(test close-store-stops-the-worker
  (fresh-store)
  (let ((worker (bknr.hashkv:start-worker)))
    (bknr.hashkv:close-store)
    (is-false (bknr.hashkv:worker-running-p worker))))

(test worker-running-p-without-a-store-is-false
  (bknr.hashkv:close-store)
  (is-false (bknr.hashkv:worker-running-p)))

(test submit-to-a-stopped-worker-signals
  (with-fresh-store
    (bknr.hashkv:start-worker)
    (bknr.hashkv:stop-worker)
    (signals error (bknr.hashkv:submit :get "k"))))

(test submit-signals-worker-errors-in-caller-and-worker-survives
  (with-fresh-store
    (with-worker
      (signals type-error (bknr.hashkv:submit :frobnicate 1))
      (is-true (bknr.hashkv:worker-running-p))
      (is (string= "still up" (bknr.hashkv:submit :get (bknr.hashkv:submit :put "still up")))))))

(defun run-tests ()
  "Runs the unit suite and returns T when every test passed."
  (fiveam:run! 'bknr.hashkv-suite))
