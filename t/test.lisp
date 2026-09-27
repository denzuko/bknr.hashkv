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

(defclass unit-thing ()
  ((a :initarg :a :accessor thing-a)
   (b :initarg :b :accessor thing-b)
   (shared :allocation :class :initform :class-value :accessor thing-shared))
  (:documentation "Plain CLOS fixture with an instance slot left unbound in
some tests and a class-allocated slot that must not be stored."))

(defstruct unit-struct
  "Structure fixture."
  x y)

(bknr.datastore:defpersistent-class unit-persistent ()
  ((n :initarg :n :initform 0 :reader unit-persistent-n))
  (:documentation "Persistent fixture, stored by reference."))

(defun round-trip (value)
  "Returns VALUE after conversion to its stored form and back."
  (bknr.hashkv::value-from-form (bknr.hashkv::stored-form value)))

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

(test hash-of-a-persistent-object-signals
  (with-fresh-store
    (signals print-not-readable
      (bknr.hashkv::hash-value (bknr.datastore:with-transaction () (make-instance 'unit-persistent))))))

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

;;; --- Stored form -----------------------------------------------------------

(test instance-round-trip-keeps-bound-slots-only
  (let ((copy (round-trip (make-instance 'unit-thing :a 1))))
    (is (typep copy 'unit-thing))
    (is (= 1 (thing-a copy)))
    (is-false (slot-boundp copy 'b))))

(test class-allocated-slots-are-not-stored
  (is-false (assoc 'shared (cddr (bknr.hashkv::stored-form (make-instance 'unit-thing :a 1))))))

(test struct-round-trip
  (let ((copy (round-trip (make-unit-struct :x 1 :y "two"))))
    (is (typep copy 'unit-struct))
    (is (equal '(1 "two") (list (unit-struct-x copy) (unit-struct-y copy))))))

(test nested-values-round-trip-fresh
  (let* ((inner (make-instance 'unit-thing :a (list 1 2) :b "s"))
         (value (list inner (vector 1 inner) '(a . b)))
         (copy (round-trip value)))
    (is (equal '(1 2) (thing-a (first copy))))
    (is-false (eq inner (first copy)))
    (is (equal '(a . b) (third copy)))
    (is (typep (aref (second copy) 1) 'unit-thing))))

(test multidimensional-and-specialized-arrays-round-trip
  (let ((grid (make-array '(2 2) :initial-contents '((1 2) (3 4))))
        (bytes (make-array 3 :element-type '(unsigned-byte 8) :initial-contents '(7 8 9))))
    (is (equalp grid (round-trip grid)))
    (is (equal '(unsigned-byte 8) (array-element-type (round-trip bytes))))))

(test hash-table-round-trip
  (let ((table (make-hash-table :test 'equal)))
    (setf (gethash "k" table) (list 1)
          (gethash "j" table) 2)
    (let ((copy (round-trip table)))
      (is (eq 'equal (hash-table-test copy)))
      (is (equal '(1) (gethash "k" copy)))
      (is (= 2 (gethash "j" copy))))))

(test equal-hash-tables-share-a-key-whatever-the-insertion-order
  (let ((first (make-hash-table)) (second (make-hash-table)))
    (setf (gethash :a first) 1 (gethash :b first) 2)
    (setf (gethash :b second) 2 (gethash :a second) 1)
    (is (string= (bknr.hashkv::hash-value first) (bknr.hashkv::hash-value second)))))

(test raw-hash-table-from-1.0.0-is-copied
  (let ((table (make-hash-table)))
    (setf (gethash :a table) (list 1))
    (let ((copy (bknr.hashkv::value-from-form table)))
      (is-false (eq table copy))
      (is (equal '(1) (gethash :a copy))))))

(test removed-slot-is-skipped-when-rebuilding
  (let ((form (list 'bknr.hashkv::%instance 'unit-thing '(a . 1) '(gone . 2))))
    (is (= 1 (thing-a (bknr.hashkv::value-from-form form))))))

(test instance-that-contains-itself-is-rejected
  (let ((thing (make-instance 'unit-thing)))
    (setf (thing-a thing) thing)
    (signals bknr.hashkv:unstorable-value-error (bknr.hashkv::stored-form thing))))

(test shared-substructure-is-not-a-cycle
  (let* ((shared (list 1 2))
         (copy (round-trip (list shared shared))))
    (is (equal '((1 2) (1 2)) copy))))

(test instance-of-an-anonymous-class-is-rejected
  (let ((class (make-instance 'standard-class :name nil :direct-superclasses (list (find-class 'standard-object)))))
    (signals bknr.hashkv:unstorable-value-error
      (bknr.hashkv::stored-form (make-instance class)))))

(test instance-of-a-class-its-name-does-not-find-is-rejected
  (let ((class (make-instance 'standard-class :name (gensym "UNREGISTERED")
                                              :direct-superclasses (list (find-class 'standard-object)))))
    (signals bknr.hashkv:unstorable-value-error
      (bknr.hashkv::stored-form (make-instance class)))))

(test complex-numbers-are-rejected
  (signals bknr.hashkv:unstorable-value-error (bknr.hashkv::stored-form #c(1 2))))

(test streams-are-rejected
  (signals bknr.hashkv:unstorable-value-error (bknr.hashkv::stored-form *standard-output*)))

(test weak-pointers-are-rejected
  (signals bknr.hashkv:unstorable-value-error (bknr.hashkv::stored-form (sb-ext:make-weak-pointer 1))))

(test unstorable-value-error-names-the-value-and-reason
  (let ((condition (nth-value 1 (ignore-errors (bknr.hashkv::stored-form #'car)))))
    (is (eq #'car (bknr.hashkv:unstorable-value-error-value condition)))
    (is (search "cannot be stored" (princ-to-string condition)))))

(test persistent-object-round-trips-by-reference
  (with-fresh-store
    (let ((object (bknr.datastore:with-transaction () (make-instance 'unit-persistent :n 3))))
      (bknr.hashkv:put-keyed "ref" (list object))
      (is (eq object (first (bknr.hashkv:get-value "ref")))))))

(test batch-put-with-an-unstorable-value-stores-nothing
  (with-fresh-store
    (signals bknr.hashkv:unstorable-value-error (bknr.hashkv:batch-put (list 1 #'car 3)))
    (is (= 0 (length (bknr.datastore:class-instances 'bknr.hashkv::kv-entry))))))

(test enqueue-of-an-unstorable-payload-signals
  (with-fresh-store
    (signals bknr.hashkv:unstorable-value-error (bknr.hashkv:enqueue #'car))
    (is-false (bknr.hashkv:dequeue-claim "c"))))

(defun run-tests ()
  "Runs the unit suite and returns T when every test passed."
  (fiveam:run! 'bknr.hashkv-suite))
