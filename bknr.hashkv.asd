;;;; bknr.hashkv.asd
;;;;
;;;; Extends bknr.datastore and depends on bknr.ttl (denzuko/bknr.ttl,
;;;; a separate repo. See that project's README for the naming
;;;; rationale, which applies here too).

(asdf:defsystem "bknr.hashkv"
  :description "Content-addressable key/value store plus a persisted job queue over bknr.datastore, with chanl-based KV request serialization and lparallel batch hashing."
  :author "Dwight Spencer"
  :license "BSD-3-Clause"
  :version "1.0.0"
  :depends-on ("bknr.datastore"
               "bknr.ttl"
               "chanl"
               "lparallel"
               "ironclad"
               "babel")
  :pathname "src/"
  :serial t
  :components ((:file "store")))

(asdf:defsystem "bknr.hashkv/docs"
  :description "40ants-doc manual definition for bknr.hashkv."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "40ants-doc")
  :pathname "src/"
  :components ((:file "docs")))

(asdf:defsystem "bknr.hashkv/tests"
  :description "FiveAM unit test suite for bknr.hashkv: exercises the store API directly, one behavior per test, no persistence-across-restart or worker-lifecycle concerns."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "fiveam" "uiop")
  :pathname "t/"
  :components ((:file "test")))

(asdf:defsystem "bknr.hashkv/e2e"
  :description "FiveAM end-to-end suite for bknr.hashkv: exercises the worker lifecycle and persistence across a store close/reopen, as a real caller would."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "fiveam" "uiop")
  :pathname "t/"
  :components ((:file "e2e")))

(asdf:defsystem "bknr.hashkv/bdd"
  :description "Step definitions for bknr.hashkv's Gherkin feature, running as ordinary FiveAM tests via sunny-side (denzuko/sunny-side), a standalone Gherkin-over-FiveAM engine. No Ruby, no wire protocol, no subprocess."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "sunny-side" "fiveam")
  :pathname "features/step_definitions/"
  :components ((:file "steps")))
