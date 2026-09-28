;;;; src/package.lisp

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
           #:reserved-key-error
           #:reserved-key-error-key
           #:unstorable-value-error
           #:unstorable-value-error-value
           #:unstorable-value-error-reason
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
