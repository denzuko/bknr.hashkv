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
;;;; QUEUE-ENTRY queue below, which is meant to be claimed by
;;;; multiple worker processes. Do not conflate the two.

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
           #:ack-claim
           #:release-claim
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
  "Handle for the task draining *REQUEST-CHANNEL*.")

(defvar *worker-stopped-channel* nil
  "Signaled by the worker just before it exits its loop, so STOP-WORKER
can wait for real completion. CHANL:PEXEC submits to a shared thread
pool rather than spawning a dedicated one-shot OS thread, so the pool
thread underlying a task does not exit when that task's body finishes
. It goes back to the pool to run other work. SB-THREAD:JOIN-THREAD on
it never returns. This channel handshake uses the same synchronization
primitive as the rest of this module instead.")

(defvar *sequence-counter* 0
  "In-memory monotonic counter for queue FIFO ordering. Reset to the
current maximum on every OPEN-STORE so a restart cannot hand out a
sequence number lower than what is already persisted.")

;;; --- Persistent classes -------------------------------------------------

(bknr.datastore:defpersistent-class kv-entry (bknr.ttl:timestamped-entry)
  ((key :initarg :key :accessor entry-key
        :index-type bknr.indices:string-unique-index
        :index-reader entry-with-key)
   (value :initarg :value :accessor entry-value))
  (:documentation "A single stored value, indexed by KEY, either a
content hash (PUT-VALUE) or a caller-supplied name (PUT-KEYED). Uses
STRING-UNIQUE-INDEX rather than plain UNIQUE-INDEX because
UNIQUE-INDEX's hash-table defaults to an EQL test, which only
matches identical string objects, not equal string content.
STRING-UNIQUE-INDEX uses an EQUAL test instead. Without this, a
key deserialized fresh from the transaction log after a restart is
never EQL to the key string that indexed it originally, even though
the two strings hold identical characters, so the index reader finds
nothing for an entry that class-instances still reports correctly."))

(bknr.datastore:defpersistent-class queue-entry (bknr.ttl:timestamped-entry)
  ((token-id :initarg :token-id :accessor entry-token-id
           :index-type bknr.indices:string-unique-index
           :index-reader entry-with-token-id)
   (sequence-number :initarg :sequence-number :accessor entry-sequence-number)
   (payload :initarg :payload :accessor entry-payload)
   (claimed-by :initarg :claimed-by :accessor entry-claimed-by :initform nil)
   (claimed-at :initarg :claimed-at :accessor entry-claimed-at :initform nil))
  (:documentation "A single queued entry. Identity (TOKEN-ID) is
generated, never a content hash. Two entries with identical PAYLOADs
are two distinct entries, which content-addressing would wrongly
collapse. Named TOKEN-ID rather than ID specifically because ID
collides with bknr.datastore:store-object's own internal identity
slot, which the datastore expects to be an auto-incrementing
integer. A string token-id in a slot literally named ID triggers a
CASE-FAILURE deep in bknr.datastore's own internals expecting that
integer. Uses STRING-UNIQUE-INDEX for the same reason KV-ENTRY does:
plain UNIQUE-INDEX defaults to an EQL hash-table test, which fails
to match a string key deserialized fresh after a restart against the
string that indexed it originally, even with identical content."))

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
it. Call this once before using any KV or queue operation.

KNOWN GAP, tracked as denzuko/bknr.hashkv#1: after a close/reopen
cycle, restored KV-ENTRY/QUEUE-ENTRY objects are found correctly by
BKNR.DATASTORE:CLASS-INSTANCES, but their unique-index readers
(ENTRY-WITH-KEY, ENTRY-WITH-JOB-ID) return NIL until something else
touches the index in that session. Four attempted workarounds were
tried and empirically ruled out, each requiring progressively deeper
BKNR.INDICES internals knowledge without working: (1) re-SETF a slot
to its own value, (2) force a real transition via SETF to NIL then
back, (3) BKNR.INDICES:INDEX-ADD with 2 args (index object), ran
without error but did not populate the index, (4) INDEX-ADD with 3
args (index key object): arity error, that overload does not exist.
Given none of these were simple, the sidestep failed the bar it was
held to (force-multiplier, atomic-component, ease-for-humans) as
badly as chasing the real fix would have, without being the real
fix, so this is left as a known, honestly-failing case rather than
a broken workaround masquerading as a fix. See the issue for the
likely real answer (BKNR.INDICES:INDEX-REINITIALIZE, called correctly,
which needs its exact contract confirmed against source outside the
sandbox this was found in)."
  (setf *store-directory* directory)
  (ensure-directories-exist directory)
  (prog1
      (make-instance 'bknr.datastore:mp-store
                      :directory directory
                      :subsystems (list (make-instance 'bknr.datastore:store-object-subsystem)))
    (bootstrap-sequence-counter)))

(defun close-store ()
  "Closes the currently open datastore, if one is open. Safe to call
even if OPEN-STORE was never called: BKNR.DATASTORE:*STORE* is
unbound until the first OPEN-STORE, not merely NIL, so a bare
reference to it would signal UNBOUND-VARIABLE instead of returning
false."
  (when (and (boundp 'bknr.datastore:*store*) bknr.datastore:*store*)
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
EXPIRES-IN-SECONDS, if given, sets a TTL relative to now. 0 or
negative expires the entry immediately, not never: NIL means \"no
TTL.\""
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
rather than content-addressed blobs. Returns KEY.

EXPIRES-IN-SECONDS 0 or negative expires the entry immediately, not
never: NIL is what means \"no TTL.\" Easy to get backwards against
APIs where 0 disables expiry instead."
  (bknr.datastore:with-transaction ()
    (let ((existing (entry-with-key key))
          (expires-at (expires-at-from expires-in-seconds)))
      (cond
        (existing
         (setf (entry-value existing) value
               (bknr.ttl:entry-expires-at existing) expires-at))
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

(defun generate-token-id ()
  "Generates a probably-unique token id. Collision odds are low enough
for a single-instance queue; a distributed deployment would want a
stronger id scheme (e.g. a UUID library). Noted as a known limit,
not solved here."
  (format nil "token-~(~36R~)-~(~36R~)" (get-universal-time) (random most-positive-fixnum)))

(defun enqueue (payload &key expires-in-seconds)
  "Adds PAYLOAD to the queue and returns its token id. Unlike
PUT-VALUE, identical payloads always get distinct entries.
EXPIRES-IN-SECONDS, if given, lets an entry expire unclaimed rather
than sitting forever."
  (let ((token-id (generate-token-id)))
    (bknr.datastore:with-transaction ()
      (make-instance 'queue-entry
                      :token-id token-id
                      :sequence-number (incf *sequence-counter*)
                      :payload payload
                      :expires-at (expires-at-from expires-in-seconds)))
    token-id))

(defun dequeue-claim (claimant-id)
  "Atomically claims the oldest unclaimed, unexpired entry for
CLAIMANT-ID. Returns (VALUES TOKEN-ID PAYLOAD), or (VALUES NIL NIL) if
nothing is claimable. The scan and the claim happen inside one
transaction so two callers cannot claim the same entry.
BKNR.DATASTORE:WITH-TRANSACTION only forwards the primary value of
its body, silently dropping secondary values, so the result is
captured into outer lexicals via SETF and returned only after
leaving the transaction form, rather than returning (VALUES ...)
directly from inside it."
  (let (result-token-id result-payload)
    (bknr.datastore:with-transaction ()
      (let* ((now (get-universal-time))
             (claimable (remove-if (lambda (e)
                                      (or (entry-claimed-by e)
                                          (bknr.ttl:entry-expired-p e now)))
                                    (bknr.datastore:class-instances 'queue-entry)))
             (candidate (first (sort claimable #'< :key #'entry-sequence-number))))
        (when candidate
          (setf (entry-claimed-by candidate) claimant-id
                (entry-claimed-at candidate) now)
          (setf result-token-id (entry-token-id candidate)
                result-payload (entry-payload candidate)))))
    (values result-token-id result-payload)))

(defun ack-claim (token-id)
  "Marks entry TOKEN-ID complete by removing it from the queue.
Returns T if a matching entry was found and removed, NIL otherwise."
  (let ((entry (entry-with-token-id token-id)))
    (unless entry
      (return-from ack-claim nil))
    (bknr.datastore:with-transaction ()
      (bknr.datastore:delete-object entry))
    t))

(defun release-claim (token-id)
  "Clears the claim on entry TOKEN-ID without removing it, making it
eligible for DEQUEUE-CLAIM again. The retry path for a claimant that
failed to finish it. Returns T if a matching entry was found, NIL
otherwise."
  (let ((entry (entry-with-token-id token-id)))
    (unless entry
      (return-from release-claim nil))
    (bknr.datastore:with-transaction ()
      (setf (entry-claimed-by entry) nil
            (entry-claimed-at entry) nil))
    t))

(defun reclaim-stale-claims (&key (older-than-seconds 300))
  "Releases any claim older than OLDER-THAN-SECONDS, so a worker that
crashed mid-claim does not leave its claim stuck forever. Returns the
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
bknr.ttl:sweep-expired so callers do not need to depend on :bknr.ttl
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
  "Starts the single worker task that drains *REQUEST-CHANNEL* and
applies each queued KV request against the store in arrival order.
A NIL request on the channel tells the worker to stop.

Idempotent: if a worker task already exists and has not reached
CHANL's :TERMINATED status, this returns the existing task rather
than starting a second one. Without this guard, a second
START-WORKER call (with no intervening STOP-WORKER) permanently
orphans the first worker task: both tasks would end up recv'ing
from the same *REQUEST-CHANNEL*, and STOP-WORKER only signals and
waits for whichever task *WORKER-THREAD* currently points at, since
that reference gets overwritten by the second call. The first task
keeps running forever
with no way to reach it through this API again."
  (when (and *worker-thread*
             (not (eq (chanl:task-status *worker-thread*) :terminated)))
    (return-from start-worker *worker-thread*))
  (unless *request-channel*
    (setf *request-channel* (make-instance 'chanl:channel)))
  (setf *worker-stopped-channel* (make-instance 'chanl:channel))
  (setf *worker-thread*
        (chanl:pexec (:name "bknr.hashkv-worker")
          (loop
            (let ((req (chanl:recv *request-channel*)))
              (unless req
                (chanl:send *worker-stopped-channel* t)
                (return))
              (chanl:send (request-reply req) (dispatch-request req)))))))

(defun stop-worker ()
  "Signals the worker to exit and waits for it to finish,
via the channel handshake set up in START-WORKER rather than joining
an OS thread (see *WORKER-STOPPED-CHANNEL*'s docstring for why)."
  (when *request-channel*
    (chanl:send *request-channel* nil))
  (when *worker-stopped-channel*
    (chanl:recv *worker-stopped-channel*))
  (setf *worker-thread* nil))

(defun submit (op arg)
  "Queues OP (:PUT, :GET, or :DELETE) with ARG on the worker thread and
blocks until the result is available. START-WORKER must be called
first. This is the KV request queue, not the QUEUE-ENTRY queue;
see the file header."
  (unless *request-channel*
    (error "bknr.hashkv worker is not running; call START-WORKER first."))
  (let ((reply (make-instance 'chanl:channel)))
    (chanl:send *request-channel* (make-request :op op :arg arg :reply reply))
    (chanl:recv reply)))
