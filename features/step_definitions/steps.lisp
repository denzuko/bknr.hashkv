;;;; features/step_definitions/steps.lisp
;;;;
;;;; Step definitions for the key/value and queue features, run as
;;;; FiveAM tests through sunny-side. Every step closes over one
;;;; lexical WORLD; the Background step replaces its contents at the
;;;; start of each scenario.

(defpackage :bknr.hashkv/bdd
  (:use :cl :sunny-side)
  (:import-from :fiveam #:is #:is-true #:is-false)
  (:export #:run-bdd))

(in-package :bknr.hashkv/bdd)

(defstruct world
  "State one scenario builds up and later steps check."
  directory key previous-key list-keys signalled thread-keys thread-errors
  token previous-token claimed-token claimed-payload ack-result
  seeded-state queued-tokens claimed-tokens)

(defclass effect ()
  ((name :initarg :name :reader effect-name)
   (damage :initarg :damage :reader effect-damage))
  (:documentation "A plain CLOS class, not a persistent class, standing in
for a game object such as a spell effect."))

(defstruct struct-effect
  "A structure standing in for a game object."
  damage)

(bknr.datastore:defpersistent-class persistent-effect ()
  ((damage :initarg :damage :reader persistent-effect-damage))
  (:documentation "A bknr persistent class, stored by reference."))

(defun make-effect (name damage)
  "Returns an EFFECT named NAME with DAMAGE, given as a digit string."
  (make-instance 'effect :name name :damage (parse-integer damage)))

(defun effect-is-p (object name damage)
  "True when OBJECT is an EFFECT named NAME with DAMAGE, given as a digit string."
  (and (typep object 'effect)
       (equal name (effect-name object))
       (= (parse-integer damage) (effect-damage object))))

(defun scratch-directory ()
  "Returns a new, unique directory pathname under the system temporary directory."
  (uiop:ensure-directory-pathname
   (merge-pathnames (format nil "bknr.hashkv-bdd-~A" (bknr.hashkv::generate-token-id))
                    (uiop:temporary-directory))))

(defun signalled-by (thunk)
  "Calls THUNK and returns the error it signals, or NIL."
  (handler-case (progn (funcall thunk) nil)
    (error (condition) condition)))

(defun run-threads (count function)
  "Runs FUNCTION on COUNT threads released together, and waits for all of them."
  (let* ((gate (bt:make-semaphore))
         (threads (loop repeat count
                        collect (bt:make-thread (lambda () (bt:wait-on-semaphore gate) (funcall function))))))
    (bt:signal-semaphore gate :count count)
    (mapc #'bt:join-thread threads)))

(defun collect-from-threads (count function)
  "Runs FUNCTION on COUNT threads at once. Returns the values it returned
and the errors it signalled, as two lists."
  (let ((lock (bt:make-lock)) (values '()) (errors '()))
    (run-threads count (lambda ()
                         (handler-case (let ((value (funcall function)))
                                         (bt:with-lock-held (lock) (push value values)))
                           (error (condition) (bt:with-lock-held (lock) (push condition errors))))))
    (values values errors)))

(defun drain (claimants)
  "Runs CLAIMANTS threads that claim until the queue is empty, and returns
every token id claimed."
  (let ((lock (bt:make-lock)) (tokens '()))
    (run-threads claimants
                 (lambda ()
                   (loop for token = (bknr.hashkv:dequeue-claim (bknr.hashkv::generate-token-id))
                         while token
                         do (bt:with-lock-held (lock) (push token tokens)))))
    tokens))

(let ((world (make-world)))
  (labels ((put (value &rest options)
             (setf (world-previous-key world) (world-key world)
                   (world-key world) (apply #'bknr.hashkv:put-value value options)))
           (queue (payload)
             (setf (world-previous-token world) (world-token world)
                   (world-token world) (bknr.hashkv:enqueue payload)))
           (seeded-queue (payload)
             (let ((*random-state* (make-random-state (world-seeded-state world))))
               (queue payload)))
           (claim (claimant)
             (multiple-value-bind (token payload) (bknr.hashkv:dequeue-claim claimant)
               (setf (world-claimed-token world) token
                     (world-claimed-payload world) payload))))

    ;; --- Store lifecycle

    (Given! "^a fresh bknr\\.hashkv store$" ()
      (bknr.hashkv:close-store)
      (setf world (make-world :directory (scratch-directory)))
      (bknr.hashkv:open-store (world-directory world)))

    (When! "^the store is closed and reopened$" ()
      (bknr.hashkv:close-store)
      (bknr.hashkv:open-store (world-directory world)))

    ;; --- Key/value

    (When! "^I put \"([^\"]*)\" into the store$" (value)
      (put value))

    (When! "^I put \"([^\"]*)\" into the store again$" (value)
      (put value))

    (When! "^I put \"([^\"]*)\" into the store with a TTL of (-?\\d+) seconds$" (value seconds)
      (put value :expires-in-seconds (parse-integer seconds)))

    (When! "^I put the list 1 2 (\\d+) into the store while print length is 2$" (last)
      (let ((*print-length* 2))
        (push (bknr.hashkv:put-value (list 1 2 (parse-integer last))) (world-list-keys world))))

    (When! "^I put \"([^\"]*)\" under the key of \"([^\"]*)\"$" (value genuine)
      (let ((key (bknr.hashkv:put-value genuine)))
        (setf (world-signalled world) (signalled-by (lambda () (bknr.hashkv:put-keyed key value))))))

    (When! "^I put a persistent object into the store by content$" ()
      (let ((object (bknr.datastore:with-transaction () (make-instance 'persistent-effect :damage 1))))
        (setf (world-signalled world) (signalled-by (lambda () (bknr.hashkv:put-value object))))))

    (When! "^I put a persistent object with damage (\\d+) under the key \"([^\"]*)\"$" (damage key)
      (bknr.hashkv:put-keyed key (bknr.datastore:with-transaction ()
                                   (make-instance 'persistent-effect :damage (parse-integer damage)))))

    (Then! "^getting \"([^\"]*)\" should return the persistent object with damage (\\d+)$" (key damage)
      (let ((value (bknr.hashkv:get-value key)))
        (is (typep value 'persistent-effect))
        (is (eql (parse-integer damage) (persistent-effect-damage value)))))

    (When! "^(\\d+) threads put \"([^\"]*)\" into the store at once$" (count value)
      (multiple-value-bind (keys errors)
          (collect-from-threads (parse-integer count) (lambda () (bknr.hashkv:put-value value)))
        (setf (world-thread-keys world) keys
              (world-thread-errors world) errors)))

    (When! "^I delete that key$" ()
      (bknr.hashkv:delete-value (world-key world)))

    (When! "^I get a key that was never stored$" ()
      (setf (world-key world) (make-string 64 :initial-element #\0)))

    (Then! "^I should get back a hash key$" ()
      (is (stringp (world-key world)))
      (is (= 64 (length (world-key world)))))

    (Then! "^getting that key should return \"([^\"]*)\"$" (expected)
      (is (equal expected (bknr.hashkv:get-value (world-key world)))))

    (Then! "^getting that key should return nothing$" ()
      (is-false (bknr.hashkv:get-value (world-key world))))

    (Then! "^both puts should return the same key$" ()
      (is (string= (world-previous-key world) (world-key world))))

    (Then! "^the two list keys should differ$" ()
      (is-false (apply #'string= (world-list-keys world))))

    (Then! "^the put should signal a reserved key error$" ()
      (is (typep (world-signalled world) 'bknr.hashkv:reserved-key-error)))

    (Then! "^the put should signal a print error$" ()
      (is (typep (world-signalled world) 'print-not-readable)))

    (Then! "^no put should have signalled an error$" ()
      (is-false (world-thread-errors world)))

    (Then! "^every put should have returned the same key$" ()
      (is (= 1 (length (remove-duplicates (world-thread-keys world) :test #'string=)))))

    (When! "^I put an effect named \"([^\"]*)\" with damage (\\d+) into the store$" (name damage)
      (put (make-effect name damage)))

    (When! "^I put an effect named \"([^\"]*)\" with damage (\\d+) into the store again$" (name damage)
      (put (make-effect name damage)))

    (Then! "^getting that key should return an effect named \"([^\"]*)\" with damage (\\d+)$" (name damage)
      (is-true (effect-is-p (bknr.hashkv:get-value (world-key world)) name damage)))

    (When! "^I put a struct effect with damage (\\d+) under the key \"([^\"]*)\"$" (damage key)
      (bknr.hashkv:put-keyed key (make-struct-effect :damage (parse-integer damage))))

    (Then! "^getting \"([^\"]*)\" should return a struct effect with damage (\\d+)$" (key damage)
      (let ((value (bknr.hashkv:get-value key)))
        (is (typep value 'struct-effect))
        (is (eql (parse-integer damage) (struct-effect-damage value)))))

    (When! "^I put the list 1 2 3 into the store and then change its last element to 99$" ()
      (let ((list (list 1 2 3)))
        (put list)
        (setf (third list) 99)))

    (When! "^I put the list 1 2 3 into the store$" ()
      (put (list 1 2 3)))

    (When! "^I change the last element of the list read from the store to 99$" ()
      (setf (third (bknr.hashkv:get-value (world-key world))) 99))

    (Then! "^getting that key should return the list 1 2 3$" ()
      (is (equal '(1 2 3) (bknr.hashkv:get-value (world-key world)))))

    (When! "^I put a function into the store$" ()
      (setf (world-signalled world) (signalled-by (lambda () (bknr.hashkv:put-value #'car)))))

    (When! "^I put a circular list into the store$" ()
      (let ((list (list 1 2 3)))
        (setf (cdr (last list)) list)
        (setf (world-signalled world) (signalled-by (lambda () (bknr.hashkv:put-value list))))))

    (Then! "^the put should signal an unstorable value error$" ()
      (is (typep (world-signalled world) 'bknr.hashkv:unstorable-value-error)))

    ;; --- Queue

    (When! "^I queue \"([^\"]*)\" onto the queue$" (payload)
      (queue payload))

    (When! "^I queue \"([^\"]*)\" onto the queue again$" (payload)
      (queue payload))

    (When! "^I queue \"([^\"]*)\" onto the queue from a freshly seeded random state$" (payload)
      (setf (world-seeded-state world) (make-random-state nil))
      (seeded-queue payload))

    (When! "^I queue \"([^\"]*)\" onto the queue from the same freshly seeded random state$" (payload)
      (seeded-queue payload))

    (When! "^I queue (\\d+) entries onto the queue$" (count)
      (setf (world-queued-tokens world)
            (loop for i below (parse-integer count) collect (bknr.hashkv:enqueue i))))

    (When! "^I queue an effect named \"([^\"]*)\" with damage (\\d+) onto the queue$" (name damage)
      (queue (make-effect name damage)))

    (Then! "^a claimant claiming the next entry should find an effect named \"([^\"]*)\" with damage (\\d+)$" (name damage)
      (claim "claimant-3")
      (is-true (effect-is-p (world-claimed-payload world) name damage)))

    (When! "^(\\d+) claimants drain the queue at once$" (count)
      (setf (world-claimed-tokens world) (drain (parse-integer count))))

    (When! "^a claimant claims the next entry$" ()
      (claim "claimant-1"))

    (When! "^another claimant claims the next entry$" ()
      (claim "claimant-2"))

    (When! "^the claimant acknowledges that claim$" ()
      (setf (world-ack-result world) (bknr.hashkv:ack-claim (world-claimed-token world))))

    (When! "^the claimant acknowledges the token id \"([^\"]*)\"$" (token)
      (setf (world-ack-result world) (bknr.hashkv:ack-claim token)))

    (When! "^the claimant releases that claim$" ()
      (bknr.hashkv:release-claim (world-claimed-token world)))

    (Then! "^I should get back a token id$" ()
      (is (stringp (world-token world))))

    (Then! "^both queued entries should have different token ids$" ()
      (is-false (string= (world-previous-token world) (world-token world))))

    (Then! "^the claimed payload should be \"([^\"]*)\"$" (expected)
      (is (equal expected (world-claimed-payload world))))

    (Then! "^the second claim should find nothing$" ()
      (is-false (world-claimed-token world)))

    (Then! "^the acknowledgement should be refused$" ()
      (is-false (world-ack-result world)))

    (Then! "^every entry should have been claimed exactly once$" ()
      (is (= (length (world-queued-tokens world)) (length (world-claimed-tokens world))))
      (is-false (set-exclusive-or (world-queued-tokens world) (world-claimed-tokens world) :test #'string=)))

    (Then! "^a claimant claiming the next entry should find nothing$" ()
      (claim "claimant-3")
      (is-false (world-claimed-token world)))

    (Then! "^a claimant claiming the next entry should find \"([^\"]*)\"$" (expected)
      (claim "claimant-3")
      (is (equal expected (world-claimed-payload world))))))

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv.feature")
  :suite bknr.hashkv-gherkin-suite)

(define-feature-tests
    #.(asdf:system-relative-pathname :bknr.hashkv "features/bknr.hashkv-queue.feature")
  :suite bknr.hashkv-queue-gherkin-suite)

(defun run-bdd ()
  "Runs both feature suites, all of them even after a failure, and returns T
when every scenario passed."
  (notany #'null (mapcar #'fiveam:run! '(bknr.hashkv-gherkin-suite bknr.hashkv-queue-gherkin-suite))))
