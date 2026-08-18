;;;; src/store.lisp
;;;;
;;;; Two distinct persisted structures over the same bknr.datastore:
;;;;
;;;;   KV-ENTRY    : content-addressed by default (PUT-VALUE hashes
;;;;                 the payload; identical values dedupe to one key),
;;;;                 or explicitly keyed (PUT-KEYED) for named slots
;;;;                 like sessions or counters. Both support TTL.
;;;;
;;;;   QUEUE-ENTRY : identity is always generated, never content-
;;;;                 derived, because two independently enqueued jobs
;;;;                 with identical payloads must stay two entries.
;;;;                 FIFO via a sequence number; claiming is atomic;
;;;;                 stale claims are reclaimable.
;;;;
;;;; Both inherit bknr.ttl:timestamped-entry (see ttl.lisp in bknr.ttl) for
;;;; CREATED-AT/EXPIRES-AT rather than declaring it twice.
;;;;
;;;; chanl still serializes ad hoc :put/:get/:delete requests through
;;;; SUBMIT, as before. That is a request-serialization queue local
;;;; to one Lisp image, and is a different thing from the persisted
;;;; QUEUE-ENTRY job queue below, which is meant to be claimed by
;;;; multiple worker processes. Don't conflate the two.

(defpackage :bknr.hashkv
  (:use :cl)
  (:export ;; store lifecycle
           #:open-store
           #:close-store
           ;; KV
           #:put-value
           #:put-keyed
           #:get-value
           #:delete-value
           #:batch-put
           ;; queue
           #:enqueue
           #:dequeue-claim
           #:ack-job
           #:release-job
           #:reclaim-stale-claims
           ;; maintenance
           #:sweep-expired
           ;; chanl request-serialization worker (KV only)
           #:start-worker
           #:stop-worker
           #:submit))

(in-package :bknr.hashkv)

;;; --- State ------------------------------------------------------------

(defvar *store-directory* #P"/tmp/bknr.hashkv-store/"
  "Filesystem location of the bknr.datastore snapshot and transaction log.")

(defvar *worker-kernel* nil
  "lparallel kernel used for parallel hashing during batch operations.")

(defvar *request-channel* nil
  "chanl channel that serializes KV mutations through a single worker thread.")

(defvar *worker-thread* nil
  "Handle for the thread draining *REQUEST-CHANNEL*.")

(defvar *sequence-counter* 0
  "In-memory monotonic counter for queue FIFO ordering. Reset to the
current maximum on every OPEN-STORE so a restart cannot hand out a
sequence number lower than what is already persisted.")

;;; --- Persistent classes -------------------------------------------------

(bknr.datastore:defpersistent-class kv-entry (bknr.ttl:timestamped-entry)
  ((key :initarg :key :accessor entry-key
        :index-type bknr.indices:unique-index
        :index-reader entry-with-key)
   (value :initarg :value :accessor entry-value))
  (:documentation "A single stored value, indexed by KEY, either a
content hash (PUT-VALUE) or a caller-supplied name (PUT-KEYED)."))

(bknr.datastore:defpersistent-class queue-entry (bknr.ttl:timestamped-entry)
  ((id :initarg :id :accessor entry-id
       :index-type bknr.indices:unique-index
       :index-reader entry-with-id)
   (sequence-number :initarg :sequence-number :accessor entry-sequence-number)
   (payload :initarg :payload :accessor entry-payload)
   (claimed-by :initarg :claimed-by :accessor entry-claimed-by :initform nil)
   (claimed-at :initarg :claimed-at :accessor entry-claimed-at :initform nil))
  (:documentation "A single queued job. Identity (ID) is generated,
never a content hash. Two jobs with identical PAYLOADs are two
distinct entries, which content-addressing would wrongly collapse."))

(bknr.ttl:register-ttl-class 'kv-entry)
(bknr.ttl:register-ttl-class 'queue-entry)

(defun bootstrap-sequence-counter ()
  "Sets *SEQUENCE-COUNTER* to the highest SEQUENCE-NUMBER already
persisted, so freshly issued numbers stay monotonic across a restart.
Relies on the same unverified CLASS-INSTANCES enumeration noted in
ttl.lisp in bknr.ttl."
  (setf *sequence-counter*
        (reduce #'max
                (mapcar #'entry-sequence-number
                        (bknr.datastore:class-instances 'queue-entry))
                :initial-value 0)))

(defun open-store (&optional (directory *store-directory*))
  "Opens, or creates, the on-disk datastore at DIRECTORY and returns
it. Call this once before using any KV or queue operation."
  (setf *store-directory* directory)
  (ensure-directories-exist directory)
  (prog1
      (make-instance 'bknr.datastore:mp-store
                      :directory directory
                      :subsystems (list (bknr.datastore:make-object-subsystem)))
    (bootstrap-sequence-counter)))

(defun close-store ()
  "Closes the currently open datastore, if one is open."
  (when bknr.datastore:*store*
    (bknr.datastore:close-store)))

;;; --- Hashing --------------------------------------------------------------

(defun hash-value (value)
  "Returns the hex-encoded SHA-256 digest of VALUE's printed representation."
  (let ((bytes (babel:string-to-octets (prin1-to-string value) :encoding :utf-8)))
    (ironclad:byte-array-to-hex-string
     (ironclad:digest-sequence :sha256 bytes))))

(defun expires-at-from (expires-in-seconds)
  "Converts a relative EXPIRES-IN-SECONDS into an absolute universal
time, or NIL if EXPIRES-IN-SECONDS is NIL (never expires)."
  (when expires-in-seconds
    (+ (get-universal-time) expires-in-seconds)))

;;; --- KV operations --------------------------------------------------------

(defun put-value (value &key expires-in-seconds)
  "Stores VALUE under its content hash and returns the hash as a
string. An entry with the same hash is reused rather than duplicated.
EXPIRES-IN-SECONDS, if given, sets a TTL relative to now."
  (let ((key (hash-value value)))
    (when (entry-with-key key)
      (return-from put-value key))
    (bknr.datastore:with-transaction ()
      (make-instance 'kv-entry :key key :value value
                                :expires-at (expires-at-from expires-in-seconds)))
    key))

(defun put-keyed (key value &key expires-in-seconds)
  "Stores VALUE under the caller-supplied KEY, overwriting any
existing entry at that key. Unlike PUT-VALUE, KEY is not derived from
VALUE. Use this for named slots (session tokens, counters, config)
rather than content-addressed blobs. Returns KEY."
  (bknr.datastore:with-transaction ()
    (let ((existing (entry-with-key key))
          (expires-at (expires-at-from expires-in-seconds)))
      (cond
        (existing
         (setf (entry-value existing) value
               (entry-expires-at existing) expires-at))
        (t (make-instance 'kv-entry :key key :value value :expires-at expires-at)))))
  key)

(defun get-value (key)
  "Returns the value stored under KEY, or NIL if no entry exists or
the entry has expired. An expired entry found here is deleted on the
spot (lazy expiry) rather than waiting for SWEEP-EXPIRED."
  (let ((entry (entry-with-key key)))
    (unless entry
      (return-from get-value nil))
    (when (bknr.ttl:entry-expired-p entry)
      (bknr.datastore:with-transaction ()
        (bknr.datastore:delete-object entry))
      (return-from get-value nil))
    (entry-value entry)))

(defun delete-value (key)
  "Removes the entry stored under KEY. Returns T if an entry was
removed, or NIL if no entry existed under KEY."
  (let ((entry (entry-with-key key)))
    (unless entry
      (return-from delete-value nil))
    (bknr.datastore:with-transaction ()
      (bknr.datastore:delete-object entry))
    t))

(defun ensure-kernel ()
  "Lazily initializes the lparallel kernel used for batch hashing."
  (when *worker-kernel*
    (return-from ensure-kernel *worker-kernel*))
  (setf *worker-kernel* (lparallel:make-kernel 4))
  *worker-kernel*)

(defun batch-put (values)
  "Hashes VALUES in parallel across the lparallel kernel, then writes
each one under its computed hash on the calling thread. Datastore
transactions remain sequential regardless. Returns the list of
resulting keys, in the same order as VALUES."
  (ensure-kernel)
  (let* ((lparallel:*kernel* *worker-kernel*)
         (hashes (lparallel:pmap 'list #'hash-value values)))
    (mapcar (lambda (value key)
              (unless (entry-with-key key)
                (bknr.datastore:with-transaction ()
                  (make-instance 'kv-entry :key key :value value)))
              key)
            values hashes)))

;;; --- Queue operations -------------------------------------------------------

(defun generate-job-id ()
  "Generates a probably-unique job id. Collision odds are low enough
for a single-instance queue; a distributed deployment would want a
stronger id scheme (e.g. a UUID library). Noted as a known limit,
not solved here."
  (format nil "job-~(~36R~)-~(~36R~)" (get-universal-time) (random most-positive-fixnum)))

(defun enqueue (payload &key expires-in-seconds)
  "Adds PAYLOAD to the queue and returns its job id. Unlike PUT-VALUE,
identical payloads always get distinct entries. EXPIRES-IN-SECONDS,
if given, lets a job expire unclaimed rather than sitting forever."
  (let ((id (generate-job-id)))
    (bknr.datastore:with-transaction ()
      (make-instance 'queue-entry
                      :id id
                      :sequence-number (incf *sequence-counter*)
                      :payload payload
                      :expires-at (expires-at-from expires-in-seconds)))
    id))

(defun dequeue-claim (worker-id)
  "Atomically claims the oldest unclaimed, unexpired job for
WORKER-ID. Returns (VALUES ID PAYLOAD), or NIL if nothing is
claimable. The scan and the claim happen inside one transaction so
two callers cannot claim the same entry."
  (bknr.datastore:with-transaction ()
    (let* ((now (get-universal-time))
           (claimable (remove-if (lambda (e)
                                    (or (entry-claimed-by e)
                                        (bknr.ttl:entry-expired-p e now)))
                                  (bknr.datastore:class-instances 'queue-entry)))
           (candidate (first (sort claimable #'< :key #'entry-sequence-number))))
      (unless candidate
        (return-from dequeue-claim nil))
      (setf (entry-claimed-by candidate) worker-id
            (entry-claimed-at candidate) now)
      (values (entry-id candidate) (entry-payload candidate)))))

(defun ack-job (id)
  "Marks job ID complete by removing it from the queue. Returns T if
a matching entry was found and removed, NIL otherwise."
  (let ((entry (entry-with-id id)))
    (unless entry
      (return-from ack-job nil))
    (bknr.datastore:with-transaction ()
      (bknr.datastore:delete-object entry))
    t))

(defun release-job (id)
  "Clears the claim on job ID without removing it, making it eligible
for DEQUEUE-CLAIM again. The retry path for a worker that failed to
finish it. Returns T if a matching entry was found, NIL otherwise."
  (let ((entry (entry-with-id id)))
    (unless entry
      (return-from release-job nil))
    (bknr.datastore:with-transaction ()
      (setf (entry-claimed-by entry) nil
            (entry-claimed-at entry) nil))
    t))

(defun reclaim-stale-claims (&key (older-than-seconds 300))
  "Releases any claim older than OLDER-THAN-SECONDS, so a worker that
crashed mid-job doesn't leave its claim stuck forever. Returns the
count of claims reclaimed."
  (let ((now (get-universal-time))
        (reclaimed 0))
    (dolist (entry (bknr.datastore:class-instances 'queue-entry))
      (when (and (entry-claimed-at entry)
                 (>= (- now (entry-claimed-at entry)) older-than-seconds))
        (bknr.datastore:with-transaction ()
          (setf (entry-claimed-by entry) nil
                (entry-claimed-at entry) nil))
        (incf reclaimed)))
    reclaimed))

;;; --- Maintenance ------------------------------------------------------------

(defun sweep-expired ()
  "Deletes every expired KV-ENTRY and QUEUE-ENTRY. Thin wrapper over
bknr.ttl:sweep-expired so callers don't need to depend on :bknr.ttl
directly just to run maintenance."
  (bknr.ttl:sweep-expired))

;;; --- Concurrent request queue via chanl (KV only) ---------------------------

(defstruct request
  "A single queued KV operation. OP is one of :PUT, :GET, or :DELETE.
ARG is the value (for :PUT) or key (for :GET / :DELETE). REPLY is the
chanl channel the caller reads its result from."
  op arg reply)

(defun dispatch-request (req)
  "Applies REQ to the KV store according to its OP, and returns the result."
  (case (request-op req)
    (:put (put-value (request-arg req)))
    (:get (get-value (request-arg req)))
    (:delete (delete-value (request-arg req)))
    (t (error "Unknown bknr.hashkv request op: ~S" (request-op req)))))

(defun start-worker ()
  "Starts the single worker thread that drains *REQUEST-CHANNEL* and
applies each queued KV request against the store in arrival order.
A NIL request on the channel tells the worker to stop."
  (unless *request-channel*
    (setf *request-channel* (chanl:make-channel)))
  (setf *worker-thread*
        (chanl:pexec (:name "bknr.hashkv-worker")
          (loop
            (let ((req (chanl:recv *request-channel*)))
              (unless req
                (return))
              (chanl:send (request-reply req) (dispatch-request req)))))))

(defun stop-worker ()
  "Signals the worker thread to exit and waits for it to finish."
  (when *request-channel*
    (chanl:send *request-channel* nil))
  (unless *worker-thread*
    (return-from stop-worker))
  (sb-thread:join-thread *worker-thread* :default nil)
  (setf *worker-thread* nil))

(defun submit (op arg)
  "Queues OP (:PUT, :GET, or :DELETE) with ARG on the worker thread and
blocks until the result is available. START-WORKER must be called
first. This is the KV request queue, not the QUEUE-ENTRY job queue;
see the file header."
  (unless *request-channel*
    (error "bknr.hashkv worker is not running; call START-WORKER first."))
  (let ((reply (chanl:make-channel)))
    (chanl:send *request-channel* (make-request :op op :arg arg :reply reply))
    (chanl:recv reply)))
