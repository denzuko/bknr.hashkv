;;;; src/ci.lisp
;;;;
;;;; GitHub Actions workflow. 40ants-ci writes it to
;;;; .github/workflows/ci.yml when (40ANTS-CI:GENERATE :BKNR.HASHKV/CI)
;;;; is evaluated in an image that has loaded this system. Edit this
;;;; file, not the generated YAML.

(defpackage :bknr.hashkv/ci
  (:use :cl)
  (:import-from #:40ants-ci/workflow #:defworkflow)
  (:import-from #:40ants-ci/jobs/lisp-job)
  (:import-from #:40ants-ci/steps/sh))

(in-package :bknr.hashkv/ci)

(defworkflow ci
  :on-push-to "develop"
  :on-pull-request t
  :cache t
  :jobs ((40ants-ci/jobs/lisp-job:lisp-job
          :name "gate"
          :asdf-system "bknr.hashkv"
          :steps ((40ants-ci/steps/sh:sh "Gate G1-G3" ".github/scripts/gate.ros")))
         (40ants-ci/jobs/lisp-job:lisp-job
          :name "tests"
          :asdf-system "bknr.hashkv"
          :steps ((40ants-ci/steps/sh:sh "BDD" "./bknr.hashkv.ros bdd")
                  (40ants-ci/steps/sh:sh "Unit" "./bknr.hashkv.ros test")
                  (40ants-ci/steps/sh:sh "End to end" "./bknr.hashkv.ros e2e")))
         (40ants-ci/jobs/lisp-job:lisp-job
          :name "coverage"
          :asdf-system "bknr.hashkv"
          :steps ((40ants-ci/steps/sh:sh "Branch coverage, 100% required" ".github/scripts/cover.ros")))
         (40ants-ci/jobs/lisp-job:lisp-job
          :name "docs"
          :asdf-system "bknr.hashkv"
          :steps ((40ants-ci/steps/sh:sh "Render manual" "./bknr.hashkv.ros docs")))))
