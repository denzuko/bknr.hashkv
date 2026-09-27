;;;; src/docs.lisp
;;;;
;;;; The bknr.hashkv manual, defined with 40ants-doc.

(defpackage :bknr.hashkv/docs
  (:use :cl)
  (:import-from #:40ants-doc #:defsection)
  (:import-from #:40ants-doc-full/builder #:render-to-string)
  (:export #:@bknr.hashkv-manual
           #:generate))

(in-package :bknr.hashkv/docs)

(defsection @bknr.hashkv-manual (:title "bknr.hashkv")
  "A content-addressed key/value store and a persisted queue over
bknr.datastore. Both entry types expire through bknr.ttl."
  (bknr.hashkv:open-store function)
  (bknr.hashkv:close-store function)
  (bknr.hashkv:put-value function)
  (bknr.hashkv:put-keyed function)
  (bknr.hashkv:get-value function)
  (bknr.hashkv:delete-value function)
  (bknr.hashkv:batch-put function)
  (bknr.hashkv:reserved-key-error condition)
  (bknr.hashkv:enqueue function)
  (bknr.hashkv:dequeue-claim function)
  (bknr.hashkv:ack-claim function)
  (bknr.hashkv:release-claim function)
  (bknr.hashkv:reclaim-stale-claims function)
  (bknr.hashkv:sweep-expired function)
  (bknr.hashkv:start-worker function)
  (bknr.hashkv:stop-worker function)
  (bknr.hashkv:worker-running-p function)
  (bknr.hashkv:submit function))

(defun generate (&optional (stream *standard-output*) (format :markdown))
  "Writes the manual to STREAM in FORMAT, :MARKDOWN or :HTML, and returns T."
  (write-string (render-to-string @bknr.hashkv-manual :format format) stream)
  t)
