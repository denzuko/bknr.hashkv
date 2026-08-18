;;;; src/docs.lisp
;;;;
;;;; bknr.hashkv's manual, defined with 40ants-doc.
;;;;
;;;; NOTE: 40ants-doc:document's exact keyword arguments have changed
;;;; across that library's history — confirm the current signature
;;;; locally before relying on this in CI.

(defpackage :bknr.hashkv/docs
  (:use :cl)
  (:import-from #:40ants-doc #:defsection #:document)
  (:export #:@bknr.hashkv-manual
           #:generate))

(in-package :bknr.hashkv/docs)

(defsection @bknr.hashkv-manual (:title "bknr.hashkv")
  "Content-addressable KV store plus a persisted job queue, both over
bknr.datastore, both with TTL via bknr.ttl:timestamped-entry."
  (bknr.hashkv:open-store function)
  (bknr.hashkv:close-store function)
  (bknr.hashkv:put-value function)
  (bknr.hashkv:put-keyed function)
  (bknr.hashkv:get-value function)
  (bknr.hashkv:delete-value function)
  (bknr.hashkv:batch-put function)
  (bknr.hashkv:enqueue function)
  (bknr.hashkv:dequeue-claim function)
  (bknr.hashkv:ack-job function)
  (bknr.hashkv:release-job function)
  (bknr.hashkv:reclaim-stale-claims function)
  (bknr.hashkv:sweep-expired function)
  (bknr.hashkv:start-worker function)
  (bknr.hashkv:stop-worker function)
  (bknr.hashkv:submit function))

(defun generate (&optional (stream *standard-output*) (format :markdown))
  "Renders @BKNR.HASHKV-MANUAL to STREAM in FORMAT (:markdown or :html)."
  (document @bknr.hashkv-manual :stream stream :format format))
