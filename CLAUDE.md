# CLAUDE.md

Hand-authored. `.github/workflows/ci.yml` invokes
`denzuko/dps-meta@v1` (`type: lisp-actor`) on GitHub's own runners.
The first run failed (`git config meta.application is not set`)
because git config set locally in the scaffolding environment never
reaches a fresh CI checkout; the workflow now sets those keys as a CI
step directly. This file should still be treated as a placeholder
until a successful Action run regenerates it for real.

## Project Identity

| Field        | Value |
|--------------|-------|
| Application  | bknr.hashkv |
| Description  | Content-addressable key/value store plus a persisted job queue over bknr.datastore |
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
  library. It is a KV store and job queue meant to be embedded as a
  library, not a Redis clone; see README's "Architecture" section for
  the reasoning.
- Do not conflate the `chanl` request-serialization queue (`submit`,
  local to one Lisp image) with the persisted `queue-entry` job queue
  (`enqueue`/`dequeue-claim`, meant for multiple worker processes).
  See README.
- Do not use `bknr.ttl/metaclass-spike` without first verifying it
  against `bknr.datastore`'s transaction-logging internals. See
  `denzuko/bknr.ttl`'s README.
- Do not optimize `dequeue-claim`'s O(n) scan without first adding a
  `hash-list-index` on `claimed-by` (with `:index-nil t`; the default
  silently excludes unclaimed entries). See README's "Known scaling
  limit."
