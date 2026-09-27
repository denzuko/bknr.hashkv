;;;; src/store.lisp
;;;;
;;;; Two persisted structures share one bknr.datastore store.
;;;;
;;;;   KV-ENTRY     Keyed by the SHA-256 of the value's standard printed
;;;;                form (PUT-VALUE) or by a caller-supplied name
;;;;                (PUT-KEYED). Names shaped like a content hash are
;;;;                reserved for PUT-VALUE.
;;;;
;;;;   QUEUE-ENTRY  Keyed by a random token id, so identical payloads
;;;;                remain separate entries. Claimed in sequence order.
;;;;
;;;; Every read that decides a write happens inside the same
;;;; WITH-TRANSACTION as the write. The mp-store guard serializes
;;;; transactions, so the check and the write cannot interleave with
;;;; another thread.
;;;;
;;;; The chanl worker (START-WORKER, SUBMIT) serializes KV requests
;;;; within one Lisp image. It does not read or write the persisted
;;;; queue.

(defpackage :bknr.hashkv
  (:use :cl)
  (:export ;; store lifecycle
           #:*store-directory*
           #:open-store
           #:close-store
           ;; KV
           #:put-value
           #:put-keyed
           #:get-value
           #:delete-value
           #:batch-put
           #:reserved-key-error
           #:reserved-key-error-key
           ;; queue
           #:enqueue
           #:dequeue-claim
           #:ack-claim
           #:release-claim
           #:reclaim-stale-claims
           ;; maintenance
           #:sweep-expired
           ;; chanl request worker (KV only)
           #:start-worker
           #:stop-worker
           #:worker-running-p
           #:submit))

(in-package :bknr.hashkv)

;;; --- State ------------------------------------------------------------

(defvar *store-directory* nil
  "Directory of the open store's snapshot and transaction log. When NIL,
OPEN-STORE uses bknr.hashkv/ under the XDG data directory.")

(defvar *worker-kernel* nil
  "lparallel kernel used to hash BATCH-PUT values in parallel.")

(defvar *worker-kernel-lock* (bt:make-lock "bknr.hashkv kernel")
  "Serializes the first call to ENSURE-KERNEL so only one kernel is created.")

(defvar *request-channel* nil
  "chanl channel carrying KV requests to the worker task.")

(defvar *worker-thread* nil
  "The chanl task draining *REQUEST-CHANNEL*, or NIL when no worker runs.")

(defvar *worker-stopped-channel* nil
  "Channel on which the worker reports that it has left its loop.
STOP-WORKER waits on this channel instead of joining a thread, because
CHANL:PEXEC tasks run on pooled threads that do not exit.")

(defvar *sequence-counter* 0
  "Last issued queue sequence number. OPEN-STORE resets it to the highest
persisted number. Incremented only inside a transaction.")

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
   (sequence-number :initarg :sequence-number :accessor entry-sequence-number)
   (payload :initarg :payload :accessor entry-payload)
   (claimed-by :initarg :claimed-by :accessor entry-claimed-by :initform nil)
   (claimed-at :initarg :claimed-at :accessor entry-claimed-at :initform nil))
  (:documentation "A queued payload. TOKEN-ID is random, never derived from
the payload. The slot is not named ID because STORE-OBJECT already uses
that name for its integer object id."))

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

(defun bootstrap-sequence-counter ()
  "Sets *SEQUENCE-COUNTER* to the highest persisted sequence number."
  (setf *sequence-counter*
        (reduce #'max (queue-entries) :key #'entry-sequence-number :initial-value 0)))

(defun open-store (&optional (directory (or *store-directory* (default-store-directory))))
  "Opens, or creates, the store at DIRECTORY and returns it. Call once
before any KV or queue operation."
  (setf *store-directory* (uiop:ensure-directory-pathname directory))
  (ensure-directories-exist *store-directory*)
  (prog1 (make-instance 'bknr.datastore:mp-store
                        :directory *store-directory*
                        :subsystems (list (make-instance 'bknr.datastore:store-object-subsystem)))
    (bootstrap-sequence-counter)))

(defun close-store ()
  "Closes the open store. Does nothing when no store is open."
  (when (and (boundp 'bknr.datastore:*store*) bknr.datastore:*store*)
    (bknr.datastore:close-store)))

;;; --- Keys and TTL ---------------------------------------------------------

(defun hash-value (value)
  "Returns the hex SHA-256 digest of VALUE printed readably under standard
I/O syntax, so the caller's printer settings and current package do not
change the key. Signals PRINT-NOT-READABLE for values with no readable
printed form."
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence
    :sha256 (babel:string-to-octets (with-standard-io-syntax (prin1-to-string value))
                                    :encoding :utf-8))))

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
  "Stores VALUE under its content hash and returns the hash. Storing a
value that is already present replaces its expiry with the one given
here, so a re-put renews an expired or expiring entry. EXPIRES-IN-SECONDS
NIL means no expiry; 0 or a negative number expires the entry at once.
Signals PRINT-NOT-READABLE when VALUE has no readable printed form."
  (store-entry (hash-value value) value expires-in-seconds))

(defun put-keyed (key value &key expires-in-seconds)
  "Stores VALUE under the string KEY, replacing any value and expiry
already there, and returns KEY. Use for named slots such as sessions or
counters. EXPIRES-IN-SECONDS follows PUT-VALUE. Signals
RESERVED-KEY-ERROR when KEY has the form of a content hash."
  (check-type key string)
  (when (content-key-p key)
    (error 'reserved-key-error :key key))
  (store-entry key value expires-in-seconds))

(defun expire-key (key)
  "Deletes the entry under KEY if it is still expired when the transaction runs."
  (with-found-entry (entry (entry-with-key key))
    (when (bknr.ttl:entry-expired-p entry)
      (bknr.datastore:delete-object entry))))

(defun get-value (key)
  "Returns the value under KEY, or NIL when there is none or it has
expired. An expired entry is deleted when read."
  (let ((entry (entry-with-key key)))
    (cond ((null entry) nil)
          ((bknr.ttl:entry-expired-p entry) (expire-key key) nil)
          (t (entry-value entry)))))

(defun delete-value (key)
  "Deletes the entry under KEY. Returns T when an entry was deleted, NIL
when none existed."
  (with-found-entry (entry (entry-with-key key))
    (bknr.datastore:delete-object entry)
    t))

(defun ensure-kernel ()
  "Returns the lparallel kernel for batch hashing, creating it on first use."
  (bt:with-lock-held (*worker-kernel-lock*)
    (or *worker-kernel*
        (setf *worker-kernel* (lparallel:make-kernel 4 :name "bknr.hashkv")))))

(defun batch-put (values &key expires-in-seconds)
  "Hashes VALUES in parallel, then stores each one as PUT-VALUE would, in
order, one transaction per value. Returns the keys in the order of
VALUES. The batch is not atomic: an error leaves earlier values stored."
  (let* ((lparallel:*kernel* (ensure-kernel))
         (keys (lparallel:pmap 'list #'hash-value values)))
    (mapcar (lambda (key value) (store-entry key value expires-in-seconds))
            keys values)))

;;; --- Queue operations -------------------------------------------------------

(defun generate-token-id ()
  "Returns 128 bits from ironclad's operating-system PRNG as 32 hex digits.
CL:RANDOM is not used because every fresh SBCL image starts from the
same *RANDOM-STATE*."
  (ironclad:byte-array-to-hex-string (ironclad:random-data 16)))

(defun enqueue (payload &key expires-in-seconds)
  "Adds PAYLOAD to the queue and returns its token id. Identical payloads
become separate entries. With EXPIRES-IN-SECONDS, an entry still
unclaimed at that time is no longer claimable and is removed by
SWEEP-EXPIRED."
  (let ((token-id (generate-token-id))
        (expires-at (expires-at-from expires-in-seconds)))
    (bknr.datastore:with-transaction ()
      (make-instance 'queue-entry
                     :token-id token-id
                     :sequence-number (incf *sequence-counter*)
                     :payload payload
                     :expires-at expires-at))
    token-id))

(defun claimable-p (entry now)
  "True when ENTRY is unclaimed and unexpired at NOW."
  (not (or (entry-claimed-by entry)
           (bknr.ttl:entry-expired-p entry now))))

(defun oldest-claimable (now)
  "Returns the claimable entry with the lowest sequence number, or NIL.
One pass, no sorting, and the index's own list is left untouched."
  (reduce (lambda (best entry)
            (cond ((not (claimable-p entry now)) best)
                  ((null best) entry)
                  ((< (entry-sequence-number entry) (entry-sequence-number best)) entry)
                  (t best)))
          (queue-entries)
          :initial-value nil))

(defun dequeue-claim (claimant-id)
  "Claims the oldest claimable entry for CLAIMANT-ID. Returns
(VALUES TOKEN-ID PAYLOAD), or (VALUES NIL NIL) when nothing is
claimable. The search and the claim run in one transaction."
  (destructuring-bind (&optional token-id . payload)
      (bknr.datastore:with-transaction ()
        (let* ((now (get-universal-time))
               (entry (oldest-claimable now)))
          (when entry
            (setf (entry-claimed-by entry) claimant-id
                  (entry-claimed-at entry) now)
            (cons (entry-token-id entry) (entry-payload entry)))))
    (values token-id payload)))

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

(defun worker-running-p ()
  "True when a worker task exists and has not terminated."
  (and *worker-thread*
       (not (eq :terminated (chanl:task-status *worker-thread*)))))

(defun worker-loop ()
  "Answers requests from *REQUEST-CHANNEL* until it receives NIL."
  (loop for request = (chanl:recv *request-channel*)
        while request
        do (chanl:send (request-reply request) (dispatch-request request)))
  (chanl:send *worker-stopped-channel* t))

(defun start-worker ()
  "Starts the worker task and returns it. When a worker is already
running, returns that worker instead of starting a second one."
  (unless (worker-running-p)
    (setf *request-channel* (make-instance 'chanl:channel)
          *worker-stopped-channel* (make-instance 'chanl:channel)
          *worker-thread* (chanl:pexec (:name "bknr.hashkv-worker") (worker-loop))))
  *worker-thread*)

(defun stop-worker ()
  "Stops the worker and waits until it has left its loop. Does nothing
when no worker is running."
  (when (worker-running-p)
    (chanl:send *request-channel* nil)
    (chanl:recv *worker-stopped-channel*))
  (setf *worker-thread* nil))

(defun submit (op arg)
  "Sends OP (:PUT, :GET or :DELETE) with ARG to the worker, waits, and
returns the result. A condition signalled by the operation is signalled
again in the caller's thread. Signals an error when no worker is running."
  (unless (worker-running-p)
    (error "bknr.hashkv worker is not running; call START-WORKER first."))
  (let ((reply (make-instance 'chanl:channel)))
    (chanl:send *request-channel* (make-request :op op :arg arg :reply reply))
    (destructuring-bind (status . result) (chanl:recv reply)
      (when (eq status :error)
        (error result))
      result)))
