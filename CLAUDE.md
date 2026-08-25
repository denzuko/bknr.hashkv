# CLAUDE.md

Hand-authored. `denzuko/dps-meta@v1` was tried as the CI-driven
generator for this file but has a confirmed upstream bug. Its
"Checkout dps-meta source" step fetches a `v4` ref that does not exist
in that repo, failing unconditionally for every consumer regardless
of configuration. `.github/workflows/ci.yml` runs real, working CI
instead (unit, e2e, BDD, and docs, as four separate jobs) via a plain
Roswell/qlot install, matching `denzuko/edm-engine`'s proven pattern.
This file remains a hand-authored placeholder; regenerate via
`dps-meta` once its upstream bug is fixed, or hand-maintain it going
forward.

## Project Identity

| Field        | Value |
|--------------|-------|
| Application  | bknr.hashkv |
| Description  | Content-addressable key/value store plus a persisted, TTL-aware generic queue over bknr.datastore |
| Type         | Common Lisp library |
| Version      | 1.0.0 |
| Branch       | develop |
| Licence      | BSD-3-Clause |
| Organisation | denzuko |

## Standards Stack

- ASDF umbrella system pattern: root `bknr.hashkv` plus `/docs`,
  `/tests`, `/e2e`, `/bdd` subsystems, each with a thin `.ros` wrapper
  where one applies. Core logic lives in `src/`, never in the wrapper
- Depends on two sibling repos rather than bundling their code:
  `denzuko/bknr.ttl` (TTL) and `denzuko/sunny-side` (Gherkin/BDD)
- BSD-3-Clause license
- git-flow branching, `develop` as the integration branch
- Semver: MAJOR = public API/interface break only; MINOR = new non-breaking capability; PATCH = everything else

## BDD Workflow

`features/bknr.hashkv.feature` (Gherkin, via `sunny-side`) → `./bdd.ros`
xUnit (FiveAM): `./tests.ros` (unit), `t/e2e.lisp` (worker lifecycle,
restart persistence)
code → changelog → merge → tag

## Subcommands

- `./bknr.hashkv.ros`: open the store, start the KV request worker
- `./tests.ros`: unit suite
- `./bdd.ros`: Gherkin suite
- `./docs.ros`: render the 40ants-doc manual

## Do Not

- Do not add a network protocol, pub/sub, or eviction policy to this
  library. It is a KV store and a generic queue meant to be embedded
  as a library, not a Redis clone; see README's "Architecture"
  section for the reasoning.
- Do not conflate the `chanl` request-serialization queue (`submit`,
  local to one Lisp image) with the persisted `queue-entry` structure
  (`enqueue`/`dequeue-claim`, meant for multiple claimant processes).
  See README.
- Do not use `bknr.ttl/metaclass-spike` without first verifying it
  against `bknr.datastore`'s transaction-logging internals. See
  `denzuko/bknr.ttl`'s README.
- Do not optimize `dequeue-claim`'s O(n) scan without first adding a
  `hash-list-index` on `claimed-by` (with `:index-nil t`; the default
  silently excludes unclaimed entries). See README's "Known scaling
  limit."
