;;;; bknr.hashkv.asd

(asdf:defsystem "bknr.hashkv"
  :description "Content-addressed key/value store and persisted queue over bknr.datastore, with expiry through bknr.ttl."
  :author "Dwight Spencer"
  :license "BSD-3-Clause"
  :version "1.1.0"
  :depends-on ("bknr.datastore"
               "bknr.ttl"
               "chanl"
               "closer-mop"
               "lparallel"
               "bordeaux-threads"
               "ironclad"
               "babel")
  :pathname "src/"
  :serial t
  :components ((:file "package")
               (:file "value")
               (:file "store")))

(asdf:defsystem "bknr.hashkv/docs"
  :description "40ants-doc manual definition for bknr.hashkv."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "40ants-doc" "40ants-doc-full")
  :pathname "src/"
  :components ((:file "docs")))

(asdf:defsystem "bknr.hashkv/tests"
  :description "FiveAM unit test suite for bknr.hashkv: exercises the store API directly, one behavior per test, no persistence-across-restart or worker-lifecycle concerns."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "bordeaux-threads" "chanl" "fiveam" "lparallel" "uiop")
  :pathname "t/"
  :components ((:file "test")))

(asdf:defsystem "bknr.hashkv/e2e"
  :description "FiveAM end-to-end suite for bknr.hashkv: exercises the worker lifecycle and persistence across a store close/reopen, as a real caller would."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "bordeaux-threads" "fiveam" "uiop")
  :pathname "t/"
  :components ((:file "e2e")))

(asdf:defsystem "bknr.hashkv/bdd"
  :description "Step definitions for bknr.hashkv's Gherkin feature, running as ordinary FiveAM tests via sunny-side (denzuko/sunny-side), a standalone Gherkin-over-FiveAM engine. No Ruby, no wire protocol, no subprocess."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "sunny-side" "fiveam" "bordeaux-threads" "uiop")
  :pathname "features/step_definitions/"
  :components ((:file "steps")))

(asdf:defsystem "bknr.hashkv/ci"
  :description "40ants-ci definition of the GitHub Actions workflow."
  :license "BSD-3-Clause"
  :depends-on ("bknr.hashkv" "40ants-ci")
  :pathname "src/"
  :components ((:file "ci")))
