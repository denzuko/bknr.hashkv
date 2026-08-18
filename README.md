# bknr.hashkv

A content-addressable key/value store plus a persisted job queue,
both over `bknr.datastore`, implemented in Common Lisp.

## Naming

This extends `bknr.datastore`; it is not part of the bknr project
itself. `bknr.indices`, `bknr.impex`, and `bknr.datastore` are sibling
systems shipped from the bknr project's own repository — this one
isn't. It's `denzuko/bknr.hashkv`, a separate, independently published
project. Quicklisp's system namespace is flat, not hierarchical, so
nothing prevents the dotted name; the repo path is what actually
discloses provenance, the same reasoning applied to `denzuko/bknr.ttl`
below.

## Architecture

`bknr.hashkv.asd` defines five systems: `bknr.hashkv`, `bknr.hashkv/docs`,
`bknr.hashkv/tests`, `bknr.hashkv/e2e`, and `bknr.hashkv/bdd`, each with
a thin `.ros` wrapper where one applies (`bknr.hashkv.ros`, `docs.ros`,
`tests.ros`, `bdd.ros`). Core functionality lives in `src/`, not in the
wrapper scripts.

| Component          | Responsibility                                                  |
|---------------------|------------------------------------------------------------------|
| `bknr.datastore`    | Persistence — on-disk snapshot and transaction log               |
| `bknr.ttl`          | TTL — `timestamped-entry` mixin (`created-at`/`expires-at`), its own repo (`denzuko/bknr.ttl`) so other projects can depend on just it |
| `sunny-side`        | Gherkin/BDD — pure-Lisp `.feature`-to-FiveAM engine, its own repo (`denzuko/sunny-side`), not bknr-specific at all |
| `ironclad` + `babel`| Hashing — SHA-256 digest of a value's printed representation     |
| `chanl`             | Concurrency — serializes ad hoc KV requests through one worker thread |
| `lparallel`         | Parallelism — hashes batches of values across a worker kernel     |

**Two separate structures share the same store on purpose:**

- `kv-entry` — content-addressed by default (`put-value` hashes the
  payload; identical values dedupe to one key), or explicitly keyed
  (`put-keyed`) for named slots like sessions or counters.
- `queue-entry` — identity is always generated, never content-derived,
  because two independently enqueued jobs with identical payloads must
  stay two entries; content-addressing would wrongly collapse them.
  FIFO via a sequence number; claiming (`dequeue-claim`) is atomic;
  stale claims (a worker that died mid-job) are reclaimable via
  `reclaim-stale-claims`.

Both inherit TTL from `bknr.ttl:timestamped-entry` rather than
declaring it twice.

**Two different "queue" concepts appear in this codebase — they are
not the same thing.** `chanl`'s `*request-channel*`/`submit` is a
request-serialization queue local to one Lisp image, used only for
ad hoc KV `:put`/`:get`/`:delete` calls. The persisted `queue-entry`
job queue (`enqueue`/`dequeue-claim`/`ack-job`) is meant to be claimed
by multiple worker processes and survives a restart. Don't wire one
into the other without thinking through what changes.

**Known scaling limit:** `dequeue-claim` and `reclaim-stale-claims`
both enumerate every `queue-entry` and scan/sort in Lisp — O(n) per
claim. `bknr.indices` ships hash-table-backed indices (`unique-index`,
`hash-index`, `hash-list-index`) but no ordered/range index, so there
is no built-in equivalent of Postgres's partial B-tree on
`WHERE claimed_by IS NULL`. A `hash-list-index` on `claimed_by` (with
`:index-nil t` — the default silently excludes NIL-valued slots,
which is exactly the unclaimed case) would narrow the scan to just
the unclaimed set; true O(log n) "first unclaimed" ordering would
need a custom sorted index class written against `bknr.indices`'
documented extension protocol. Neither is implemented yet — worth a
scoped follow-up before real job volume.

This deliberately does not attempt to be a Redis clone: no pub/sub, no
wire protocol, no eviction policy, no replication. Those solve "be a
Redis"; the goal here is a KV store and a job queue that other
projects can embed as a library — no second service to operate, one
persistence substrate (`bknr.datastore`) shared with the rest of the
org's projects rather than three storage models to reason about.

## Setup

```sh
ros init bknr.hashkv
ros install qlot
qlot add bknr.datastore chanl lparallel ironclad babel fiveam
```

`bknr.ttl` and `sunny-side` are separate repos (`denzuko/bknr.ttl`,
`denzuko/sunny-side`), not yet published to Quicklisp/Ultralisp. Until
they are, clone both as siblings and either symlink them into
`.qlot/local-projects/` or `~/.roswell/local-projects/`, or add them
as qlot local overrides.

No `QUICKLISP_HOME` export or `qlot exec` wrapper is required at
invocation time otherwise. Once qlot has been used against the
project, the Roswell script header places `.qlot/` on the load path
automatically.

## Usage

Open the store and start the worker:

```sh
./bknr.hashkv.ros
```

From a REPL loading the `:bknr.hashkv` system directly:

```lisp
(bknr.hashkv:open-store)
(bknr.hashkv:start-worker)

(bknr.hashkv:submit :put "hello world")   ;=> "b94d27b9934d3e08a52e52d7da7dacefb..."
(bknr.hashkv:submit :get *)               ;=> "hello world"
(bknr.hashkv:submit :delete *)            ;=> T

(bknr.hashkv:stop-worker)
(bknr.hashkv:close-store)
```

Batch hashing bypasses the worker and parallelizes across the
`lparallel` kernel directly:

```lisp
(bknr.hashkv:batch-put '(1 2 3 "four"))
```

Caller-supplied keys and TTL, for named slots rather than
content-addressed blobs:

```lisp
(bknr.hashkv:put-keyed "session:abc123" "user-42" :expires-in-seconds 3600)
(bknr.hashkv:get-value "session:abc123")   ;=> "user-42" until it expires,
                                            ;   then NIL (lazy expiry)
```

The persisted job queue — note this is separate from the
`start-worker`/`submit` KV request queue above:

```lisp
(bknr.hashkv:enqueue '(:resize-thumbnail "media/abc.jpg"))

(multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "worker-7")
  (when id
    (process payload)
    (bknr.hashkv:ack-job id)))            ; success — remove it
    ;; or (bknr.hashkv:release-job id)    ; failure — make it claimable again

;; Run periodically (e.g. from a cron-style task) to recover jobs
;; whose worker died mid-claim without acking or releasing:
(bknr.hashkv:reclaim-stale-claims :older-than-seconds 300)
```

## Testing

Two FiveAM suites are kept separate:

```sh
./tests.ros   # unit — bknr.hashkv/tests, exercises PUT-VALUE/GET-VALUE/etc.
              # directly, one behavior per test
```

```sh
ros run --load t/e2e.lisp --eval '(bknr.hashkv/e2e:run-e2e)' --quit
```

`bknr.hashkv/e2e` exercises the worker lifecycle through `submit`
rather than calling the store functions directly, and includes a
close-store/open-store cycle to guard against a transaction log that
looks correct in-process but doesn't actually survive a restart. Both
suites run against scratch datastores under `/tmp/`, deleted and
recreated before each test.

### BDD (Gherkin, via sunny-side — no Ruby)

`features/bknr.hashkv.feature` is Gherkin, and it's the thing that
actually runs, not documentation alongside a separately maintained
test suite: `sunny-side` (`denzuko/sunny-side`) is a standalone
pure-Lisp Gherkin engine — a small hand-rolled parser
(Feature/Background/Scenario/Given-When-Then-And-But) that turns each
Scenario into an ordinary FiveAM test at compile time — and
`features/step_definitions/steps.lisp` implements the step bodies
against `bknr.hashkv` using `fiveam:is`, the same assertion style as
`t/test.lisp` and `t/e2e.lisp`.

```sh
./bdd.ros
```

This replaced an earlier `clucumber`-based version of this layer.
`clucumber` (`antifuchs/clucumber`) implements only the Lisp side of
the Cucumber *wire protocol* — something still has to parse `.feature`
files and drive it over a socket, and that's the Ruby `cucumber` gem
itself, not an optional add-on. That meant a second language toolchain
(`Gemfile`, `bundle install`, the Ruby `cucumber` CLI) just to run
tests for a Lisp library — the same "no second thing to operate"
objection that ruled out Redis and Postgres for the store itself
applies here too. The trade-off: `sunny-side`'s parser only covers the
Gherkin subset actually in use (no `Scenario Outline`/`Examples`
tables, no data tables, no doc strings, no tags) — real, but scoped
and extendable rather than externally imposed.

`sunny-side` was originally written inline in this project
(`src/gherkin.lisp`) and pulled out into its own repo once it was
clear the engine wasn't `bknr.hashkv`-specific — nothing in it touches
`bknr.datastore` or anything else here. `bknr.hashkv` is its reference
consumer, not a special case.

**Lower risk than the rest of this project's unverified pieces**:
`sunny-side` and `steps.lisp` are code this project owns, not guesses
at a third-party library's API surface. Still genuinely untested — no
SBCL/Quicklisp available in this environment to run it — so treat it
as needing a real run before trusting it in CI, same as everything
else here.

## Documentation

```sh
./docs.ros
```

Renders `@BKNR.HASHKV-MANUAL` (defined in `src/docs.lisp`) via
`40ants-doc`. The exact keyword arguments accepted by
`40ants-doc:document` have changed across that library's history —
confirm the current signature locally before wiring this into CI.

## License

BSD 3-Clause. See `LICENSE`.
