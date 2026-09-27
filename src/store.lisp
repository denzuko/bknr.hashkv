;;;; src/store.lisp
;;;;
;;;; Two persisted structures share one bknr.datastore store.
;;;;
;;;;   KV-ENTRY     Keyed by the SHA-256 of the value's stored form
;;;;                (PUT-VALUE) or by a caller-supplied name
;;;;                (PUT-KEYED). Names shaped like a content hash are
;;;;                reserved for PUT-VALUE.
;;;;
;;;;   QUEUE-ENTRY  Keyed by a random token id, so identical payloads
;;;;                remain separate entries. Claimed in object id order.
;;;;
;;;; Values and payloads are stored as the form STORED-FORM returns and
;;;; read back through VALUE-FROM-FORM (src/value.lisp).
;;;;
;;;; Every read that decides a write happens inside the same
;;;; WITH-TRANSACTION as the write. The mp-store guard serializes
;;;; transactions, so the check and the write cannot interleave with
;;;; another thread.
;;;;
;;;; The chanl worker (START-WORKER, SUBMIT) serializes KV requests
;;;; within one Lisp image. It does not read or write the persisted
;;;; queue.

(in-package :bknr.hashkv)

;;; --- Conditions ---------------------------------------------------------

(define-condition reserved-key-error (error)
  ((key :initarg :key :reader reserved-key-error-key))
  (:report (lambda (condition stream)
             (format stream "~S has the form of a content hash; ~
                             those keys are reserved for PUT-VALUE."
                     (reserved-key-error-key condition))))
  (:documentation "Signalled by PUT-KEYED when KEY is 64 lowercase hex
digits, the form PUT-VALUE uses for content keys. Accepting such a key
would let a named write replace a content-addressed value."))

;;; --- Persistent classes -------------------------------------------------

(bknr.datastore:defpersistent-class kv-entry (bknr.ttl:timestamped-entry)
  ((key :initarg :key :accessor entry-key
        :index-type bknr.indices:string-unique-index
        :index-reader entry-with-key)
   (value :initarg :value :accessor entry-value))
  (:documentation "A stored value and its key. The key index compares with
EQUAL, so keys read back from the transaction log after a restart still
match."))

(bknr.datastore:defpersistent-class queue-entry (bknr.ttl:timestamped-entry)
  ((token-id :initarg :token-id :accessor entry-token-id
             :index-type bknr.indices:string-unique-index
             :index-reader entry-with-token-id)
   (sequence-number :initarg :sequence-number :initform nil)
   (payload :initarg :payload :accessor entry-payload)
   (claimed-by :initarg :claimed-by :accessor entry-claimed-by :initform nil)
   (claimed-at :initarg :claimed-at :accessor entry-claimed-at :initform nil))
  (:documentation "A queued payload. TOKEN-ID is random, never derived from
the payload. The slot is not named ID because STORE-OBJECT already uses
that name for its integer object id. Entries are ordered by that object
id. SEQUENCE-NUMBER is no longer written; it stays in the class because
bknr.datastore refuses to restore a snapshot that names a slot the class
lacks, and 1.0.0 stores carry it."))

(bknr.ttl:register-ttl-class 'kv-entry)
(bknr.ttl:register-ttl-class 'queue-entry)

;;; --- Store lifecycle ----------------------------------------------------

(defun default-store-directory ()
  "Returns bknr.hashkv/ under the XDG data directory."
  (uiop:xdg-data-home "bknr.hashkv/"))

(defun queue-entries ()
  "Returns every QUEUE-ENTRY. The list belongs to bknr.indices; callers
must not modify it."
  (bknr.datastore:class-instances 'queue-entry))

(defclass hashkv-store (bknr.datastore:mp-store)
  ((worker :initform nil :accessor store-worker
           :documentation "The WORKER started for this store, or NIL."))
  (:documentation "The store OPEN-STORE returns. Holds the KV worker so
START-WORKER, SUBMIT and STOP-WORKER need no argument and the library
keeps no state of its own."))

(defun open-store-p ()
  "True when a store is open."
  (and (boundp 'bknr.datastore:*store*) bknr.datastore:*store* t))

(defun open-store (&optional (directory (default-store-directory)))
  "Opens, or creates, the store at DIRECTORY and returns it. Call once
before any KV or queue operation."
  (let ((directory (ensure-directories-exist (uiop:ensure-directory-pathname directory))))
    (make-instance 'hashkv-store
                   :directory directory
                   :subsystems (list (make-instance 'bknr.datastore:store-object-subsystem)))))

(defun close-store ()
  "Stops the open store's worker, if any, and closes the store. Does
nothing when no store is open."
  (when (open-store-p)
    (stop-worker)
    (bknr.datastore:close-store)))

;;; --- Keys and TTL ---------------------------------------------------------

(defun form-hash (form)
  "Returns the hex SHA-256 digest of FORM, a stored form, printed readably
under standard I/O syntax, so the caller's printer settings and current
package do not change the key. Signals PRINT-NOT-READABLE when FORM holds
a persistent store object, which has no readable printed form."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256 (babel:string-to-octets (with-standard-io-syntax (prin1-to-string form))
                                    :encoding :utf-8))))

(defun hash-value (value)
  "Returns the content key PUT-VALUE would store VALUE under."
  (form-hash (stored-form value)))

(defun content-key-p (key)
  "True when KEY is 64 lowercase hex digits, the form HASH-VALUE returns."
  (and (= 64 (length key))
       (every (lambda (c) (find c "0123456789abcdef")) key)))

(defun expires-at-from (expires-in-seconds)
  "Converts EXPIRES-IN-SECONDS to an absolute universal time. NIL stays NIL."
  (when expires-in-seconds
    (+ (get-universal-time) expires-in-seconds)))

(defun store-entry (key value expires-in-seconds)
  "Writes VALUE and a new expiry under KEY in one transaction, creating
the entry or replacing both fields of the existing one. Returns KEY."
  (let ((expires-at (expires-at-from expires-in-seconds)))
    (bknr.datastore:with-transaction ()
      (let ((entry (entry-with-key key)))
        (cond (entry (setf (entry-value entry) value
                           (bknr.ttl:entry-expires-at entry) expires-at))
              (t (make-instance 'kv-entry :key key :value value :expires-at expires-at)))))
    key))

(defmacro with-found-entry ((var lookup) &body body)
  "Evaluates LOOKUP and, when it finds an entry, evaluates it again inside a
transaction, binds VAR to the result and runs BODY when VAR is still
non-NIL. The first lookup keeps a miss from writing an empty transaction
to the log; the second is the one the write depends on. Returns the value
of BODY, or NIL."
  `(when ,lookup
     (bknr.datastore:with-transaction ()
       (let ((,var ,lookup))
         (when ,var ,@body)))))

;;; --- KV operations --------------------------------------------------------

(defun put-value (value &key expires-in-seconds)
  "Stores a copy of VALUE under the hash of its stored form and returns the
hash. Equal values, including instances of the same class with equal
slots, share one key. Storing a value that is already present replaces
its expiry with the one given here, so a re-put renews an expired or
expiring entry. EXPIRES-IN-SECONDS NIL means no expiry; 0 or a negative
number expires the entry at once. Signals UNSTORABLE-VALUE-ERROR as
STORED-FORM does, and PRINT-NOT-READABLE when VALUE holds a persistent
store object; store those with PUT-KEYED."
  (let ((form (stored-form value)))
    (store-entry (form-hash form) form expires-in-seconds)))

(defun put-keyed (key value &key expires-in-seconds)
  "Stores a copy of VALUE under the string KEY, replacing any value and
expiry already there, and returns KEY. Use for named slots such as
sessions or counters, and for values that hold persistent store
objects. EXPIRES-IN-SECONDS follows PUT-VALUE. Signals
RESERVED-KEY-ERROR when KEY has the form of a content hash, and
UNSTORABLE-VALUE-ERROR as STORED-FORM does."
  (check-type key string)
  (when (content-key-p key)
    (error 'reserved-key-error :key key))
  (store-entry key (stored-form value) expires-in-seconds))

(defun expire-key (key)
  "Deletes the entry under KEY if it is still expired when the transaction runs."
  (with-found-entry (entry (entry-with-key key))
    (when (bknr.ttl:entry-expired-p entry)
      (bknr.datastore:delete-object entry))))

(defun get-value (key)
  "Returns a fresh copy of the value under KEY, or NIL when there is none
or it has expired. An expired entry is deleted when read. Changing the
returned value does not change the store."
  (let ((entry (entry-with-key key)))
    (cond ((null entry) nil)
          ((bknr.ttl:entry-expired-p entry) (expire-key key) nil)
          (t (value-from-form (entry-value entry))))))

(defun delete-value (key)
  "Deletes the entry under KEY. Returns T when an entry was deleted, NIL
when none existed."
  (with-found-entry (entry (entry-with-key key))
    (bknr.datastore:delete-object entry)
    t))

(defun call-with-kernel (function)
  "Calls FUNCTION with an lparallel kernel. Uses the caller's
LPARALLEL:*KERNEL* when one is bound; otherwise creates a four-worker
kernel for this call and ends it before returning."
  (cond (lparallel:*kernel* (funcall function))
        (t (let ((lparallel:*kernel* (lparallel:make-kernel 4 :name "bknr.hashkv batch")))
             (unwind-protect (funcall function)
               (lparallel:end-kernel :wait t))))))

(defun form-and-hash (value)
  "Returns (hash . stored-form) for VALUE, or the error the conversion
signalled. Returning the error keeps it out of the lparallel worker,
whose default is to enter the debugger in its own thread."
  (handler-case (let ((form (stored-form value)))
                  (cons (form-hash form) form))
    (error (condition) condition)))

(defun batch-put (values &key expires-in-seconds)
  "Converts and hashes VALUES in parallel, then stores each one as
PUT-VALUE would, in order, one transaction per value. Returns the keys in
the order of VALUES. Every value is converted before any is stored, so
an unstorable value stores nothing and its error is signalled in the
caller's thread; an error while storing leaves earlier values stored.
Bind LPARALLEL:*KERNEL* to reuse a kernel across calls."
  (let* ((entries (call-with-kernel (lambda () (lparallel:pmap 'list #'form-and-hash values))))
         (failure (find-if (lambda (entry) (typep entry 'condition)) entries)))
    (when failure
      (error failure))
    (mapcar (lambda (entry) (store-entry (car entry) (cdr entry) expires-in-seconds))
            entries)))

;;; --- Queue operations -------------------------------------------------------

(defun generate-token-id ()
  "Returns 128 bits from ironclad's operating-system PRNG as 32 hex digits.
CL:RANDOM is not used because every fresh SBCL image starts from the
same *RANDOM-STATE*."
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defun enqueue (payload &key expires-in-seconds)
  "Adds a copy of PAYLOAD to the queue and returns its token id. Identical
payloads become separate entries. With EXPIRES-IN-SECONDS, an entry
still unclaimed at that time is no longer claimable and is removed by
SWEEP-EXPIRED. Signals UNSTORABLE-VALUE-ERROR as STORED-FORM does."
  (let ((token-id (generate-token-id))
        (form (stored-form payload))
        (expires-at (expires-at-from expires-in-seconds)))
    (bknr.datastore:with-transaction ()
      (make-instance 'queue-entry
                     :token-id token-id
                     :payload form
                     :expires-at expires-at))
    token-id))

(defun claimable-p (entry now)
  "True when ENTRY is unclaimed and unexpired at NOW."
  (not (or (entry-claimed-by entry)
           (bknr.ttl:entry-expired-p entry now))))

(defun oldest-claimable (entries now)
  "Returns the entry of ENTRIES that is claimable at NOW and has the lowest
object id, or NIL. Object ids are allocated in transaction order, so the
lowest id is the earliest enqueue. One pass; ENTRIES is not modified."
  (reduce (lambda (best entry)
            (cond ((not (claimable-p entry now)) best)
                  ((null best) entry)
                  ((< (bknr.datastore:store-object-id entry) (bknr.datastore:store-object-id best)) entry)
                  (t best)))
          entries
          :initial-value nil))

(defun dequeue-claim (claimant-id)
  "Claims the oldest claimable entry for CLAIMANT-ID. Returns
(VALUES TOKEN-ID PAYLOAD), with PAYLOAD a fresh copy, or (VALUES NIL NIL)
when nothing is claimable. The search and the claim run in one
transaction."
  (destructuring-bind (&optional token-id . form)
      (bknr.datastore:with-transaction ()
        (let* ((now (get-universal-time))
               (entry (oldest-claimable (queue-entries) now)))
          (when entry
            (setf (entry-claimed-by entry) claimant-id
                  (entry-claimed-at entry) now)
            (cons (entry-token-id entry) (entry-payload entry)))))
    (values token-id (value-from-form form))))

(defun clear-claim (entry)
  "Removes any claim on ENTRY. Call inside a transaction."
  (setf (entry-claimed-by entry) nil
        (entry-claimed-at entry) nil))

(defun ack-claim (token-id)
  "Deletes entry TOKEN-ID from the queue. Returns T when it existed, NIL
otherwise."
  (with-found-entry (entry (entry-with-token-id token-id))
    (bknr.datastore:delete-object entry)
    t))

(defun release-claim (token-id)
  "Clears the claim on entry TOKEN-ID so DEQUEUE-CLAIM can return it
again. Returns T when the entry exists, NIL otherwise."
  (with-found-entry (entry (entry-with-token-id token-id))
    (clear-claim entry)
    t))

(defun stale-claim-p (entry now older-than-seconds)
  "True when ENTRY was claimed at least OLDER-THAN-SECONDS before NOW."
  (let ((claimed-at (entry-claimed-at entry)))
    (and claimed-at (>= (- now claimed-at) older-than-seconds))))

(defun reclaim-stale-claims (&key (older-than-seconds 300))
  "Clears every claim at least OLDER-THAN-SECONDS old, in one transaction,
so entries held by a claimant that stopped are claimable again. Returns
the number of claims cleared."
  (bknr.datastore:with-transaction ()
    (let ((now (get-universal-time)))
      (count-if (lambda (entry)
                  (when (stale-claim-p entry now older-than-seconds)
                    (clear-claim entry)
                    t))
                (queue-entries)))))

;;; --- Maintenance ------------------------------------------------------------

(defun sweep-expired ()
  "Deletes every expired KV-ENTRY and QUEUE-ENTRY and returns the count.
Calls BKNR.TTL:SWEEP-EXPIRED."
  (bknr.ttl:sweep-expired))

;;; --- chanl request worker (KV only) ----------------------------------------

(defstruct request
  "One KV request. OP is :PUT, :GET or :DELETE. ARG is the value for :PUT
and the key otherwise. REPLY is the channel that receives the outcome."
  op arg reply)

(defun apply-op (op arg)
  "Runs the KV operation named by OP on ARG."
  (ecase op
    (:put (put-value arg))
    (:get (get-value arg))
    (:delete (delete-value arg))))

(defun dispatch-request (request)
  "Runs REQUEST and returns (:OK . result), or (:ERROR . condition) when
the operation signals. The worker never unwinds on a caller's error."
  (handler-case (cons :ok (apply-op (request-op request) (request-arg request)))
    (error (condition) (cons :error condition))))

(defstruct (worker (:constructor %make-worker))
  "A running or stopped KV worker. REQUESTS carries requests to the task,
STOPPED receives the task's exit notice, STATE is :RUNNING or :STOPPED,
and LOCK serializes changes to STATE. CHANL:PEXEC tasks run on pooled
threads that do not exit, so stopping waits on STOPPED rather than
joining a thread."
  (requests (make-instance 'chanl:channel))
  (stopped (make-instance 'chanl:channel))
  (state :running)
  (lock (bt:make-lock "bknr.hashkv worker")))

(defun worker-loop (worker)
  "Answers requests from WORKER's channel until it receives NIL."
  (loop for request = (chanl:recv (worker-requests worker))
        while request
        do (chanl:send (request-reply request) (dispatch-request request)))
  (chanl:send (worker-stopped worker) t))

(defun current-store ()
  "Returns the open store when OPEN-STORE created it, otherwise NIL."
  (and (open-store-p)
       (typep bknr.datastore:*store* 'hashkv-store)
       bknr.datastore:*store*))

(defun current-worker ()
  "Returns the worker attached to the open store, or NIL."
  (let ((store (current-store)))
    (and store (store-worker store))))

(defun worker-running-p (&optional (worker (current-worker)))
  "True when WORKER, by default the open store's worker, exists and has
not been stopped."
  (and worker (eq :running (worker-state worker))))

(defun start-worker ()
  "Starts a KV worker for the open store and returns it. When the store's
worker is already running, returns that worker instead of starting a
second one. Signals an error when no store is open."
  (let ((store (current-store)))
    (unless store
      (error "bknr.hashkv has no open store; call OPEN-STORE first."))
    (unless (worker-running-p (store-worker store))
      (let ((worker (%make-worker)))
        (chanl:pexec (:name "bknr.hashkv-worker") (worker-loop worker))
        (setf (store-worker store) worker)))
    (store-worker store)))

(defun stop-worker (&optional (worker (current-worker)))
  "Stops WORKER, by default the open store's worker, and waits until its
task has left the loop. Does nothing when there is no worker or it is
already stopped, from any thread."
  (when worker
    (bt:with-lock-held ((worker-lock worker))
      (when (worker-running-p worker)
        (setf (worker-state worker) :stopped)
        (chanl:send (worker-requests worker) nil)
        (chanl:recv (worker-stopped worker))))))

(defun submit (op arg &optional (worker (current-worker)))
  "Sends OP (:PUT, :GET or :DELETE) with ARG to WORKER, by default the open
store's worker, waits, and returns the result. A condition signalled by
the operation is signalled again in the caller's thread. Signals an
error when the worker is missing or stopped."
  (unless (worker-running-p worker)
    (error "bknr.hashkv worker is not running; call START-WORKER first."))
  (let ((reply (make-instance 'chanl:channel)))
    (chanl:send (worker-requests worker) (make-request :op op :arg arg :reply reply))
    (destructuring-bind (status . result) (chanl:recv reply)
      (when (eq status :error)
        (error result))
      result)))
