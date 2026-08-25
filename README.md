# bknr.hashkv

bknr.hashkv is a content-addressable key/value store with a
persisted, TTL-aware generic queue, both built over
`bknr.datastore`, implemented in Common Lisp. "Generic" matters here:
the queue's payload has no type constraint and its ordering, claim,
and acknowledgment primitives carry no job-execution assumptions, so
the same store supports patterns from a simple work queue up through
caller-built dependency-graph (DAG) orchestration on top of the
existing primitives, without requiring a rules engine or any other
addition to reach that.

## Naming

This library extends `bknr.datastore` rather than belonging to the
bknr project itself. `bknr.indices`, `bknr.impex`, and
`bknr.datastore` are sibling systems shipped from the bknr project's
own repository, under a single upstream authority; this project does
not join them. It exists separately, as `denzuko/bknr.hashkv`, an
independently published project. Because Quicklisp's system namespace
is flat rather than hierarchical, nothing prevents a dotted name from
outside the bknr project, so the repository path is what
discloses provenance here, the same reasoning that applies to
`denzuko/bknr.ttl` below.

## Architecture

`bknr.hashkv.asd` defines five systems: `bknr.hashkv`,
`bknr.hashkv/docs`, `bknr.hashkv/tests`, `bknr.hashkv/e2e`, and
`bknr.hashkv/bdd`, each paired with a thin `.ros` wrapper where one
applies (`bknr.hashkv.ros`, `docs.ros`, `tests.ros`, `bdd.ros`).

| Component            | Responsibility                                                        |
|-----------------------|------------------------------------------------------------------------|
| `bknr.datastore`      | Persistence: on-disk snapshot and transaction log                     |
| `bknr.ttl`             | TTL: `timestamped-entry` mixin (`created-at`/`expires-at`), its own repository (`denzuko/bknr.ttl`) so other projects can depend on just it |
| `sunny-side`           | Gherkin/BDD: pure-Lisp `.feature`-to-FiveAM engine, its own repository (`denzuko/sunny-side`), with nothing bknr-specific in it |
| `ironclad` + `babel`   | Hashing: SHA-256 digest of a value's printed representation           |
| `chanl`                | Concurrency: serializes ad hoc KV requests through one worker thread  |
| `lparallel`            | Parallelism: hashes batches of values across a worker kernel          |

Two separate structures share the same store on purpose:

- `kv-entry` is content-addressed by default: `put-value` hashes the
  payload, so identical values dedupe to one key. It can also be
  explicitly keyed through `put-keyed`, for named slots such as
  sessions or counters.
- `queue-entry`'s identity is always generated, never content-derived,
  because two independently enqueued entries with identical payloads
  need to stay two separate entries; content-addressing would
  wrongly collapse them into one. Ordering is FIFO through a sequence
  number, claiming (`dequeue-claim`) is atomic, and stale claims left
  behind by a claimant that died mid-claim are reclaimable through
  `reclaim-stale-claims`.

Both classes inherit TTL from `bknr.ttl:timestamped-entry` rather
than declaring the same slots twice.

Two different "queue" concepts appear in this codebase, and they are
not the same thing. `chanl`'s `*request-channel*` and `submit`
implement a request-serialization queue local to a single Lisp image,
used only for ad hoc KV `:put`/`:get`/`:delete` calls. The persisted
`queue-entry` structure (`enqueue`, `dequeue-claim`, `ack-claim`) is
built to be claimed by multiple claimant processes and to survive a
restart. Wiring one into the other without working through what that
change means is a mistake worth avoiding.

**Known scaling limit:** `dequeue-claim` and `reclaim-stale-claims`
both enumerate every `queue-entry` and scan and sort the result in
Lisp, which is O(n) per claim. Measured directly against a single
SBCL process running an unbuffered `mp-store` with no other load:
1.2ms per claim at 1,000 unclaimed entries, 4.8ms at 10,000, and
29.2ms at 50,000, which works out to roughly 34 claims per second at
that depth. This is fine for most queue workloads, with a real
ceiling somewhere in the tens of thousands of *simultaneously
unclaimed* entries, not total entries ever processed over the
store's lifetime.
`bknr.indices` ships hash-table-backed indices (`unique-index`,
`hash-index`, `hash-list-index`) but no ordered or range index, so
there is no built-in equivalent of a partial B-tree the way Postgres
would implement `WHERE claimed_by IS NULL`. A `hash-list-index` on
`claimed_by`, combined with `:index-nil t` since the default silently
excludes NIL-valued slots (exactly the unclaimed case), would narrow
that scan to only the unclaimed set. Reaching true O(log n) ordering
for "first unclaimed" would require a custom sorted index class
written against `bknr.indices`' documented extension protocol.
Neither improvement is implemented yet.

**Concurrency:** twenty real `chanl` threads racing to claim fifty
entries, rather than the single-threaded test suite alone, claimed
every entry exactly once with zero duplicates. The atomic-claim guarantee
holds under genuine concurrent access, confirmed against actual
threads rather than assumed from the transaction wrapper's design.

**TTL boundary:** an `expires-in-seconds` value of `0` or negative
expires an entry immediately rather than never expiring it; `NIL` is
what disables expiry. This is easy to get backwards against APIs
where `0` is the value that disables expiry instead, and it is
documented directly on both `put-value` and `put-keyed`.

This project deliberately avoids attempting to be a Redis clone: no
pub/sub, no wire protocol, no eviction policy, and no replication.
Those features solve the problem of *being* Redis, which is a
different problem from the one this library targets. The actual goal
is a key/value store and a generic queue that other projects can
embed as an ordinary library dependency, with no second service to
operate and one shared persistence substrate, `bknr.datastore`,
across the rest of the organization's projects rather than three
separate storage models
to reason about.

## Depending on bknr.hashkv from your own project

`bknr.hashkv`, `bknr.ttl`, and `sunny-side` are not yet published to
Quicklisp or Ultralisp, so add all three to your own project's
`qlfile` as git sources. qlot does not resolve a dependency's own
git-sourced dependencies transitively, so all three need to be
listed explicitly rather than `bknr.hashkv` alone:

```
git bknr.hashkv https://github.com/denzuko/bknr.hashkv.git :branch develop
git bknr.ttl https://github.com/denzuko/bknr.ttl.git :branch develop
git sunny-side https://github.com/denzuko/sunny-side.git :branch develop
```

```sh
qlot install
qlot exec ros -e '(ql:quickload :bknr.hashkv)'
```

## Development

```sh
ros init bknr.hashkv
ros install qlot
qlot install
```

`qlfile`, committed alongside this README, resolves `bknr.ttl` and
`sunny-side` the same way described above. Every script in this
repository (`./tests.ros`, `./e2e.ros`, `./bdd.ros`, `./docs.ros`,
`./bknr.hashkv.ros`) needs to run through `qlot exec`, since the
git-resolved dependencies live in this project's local `.qlot/` dist
rather than the global Quicklisp install a bare `ros` invocation
would see:

```sh
qlot exec ./tests.ros
```

`qlot exec ros build <script>.ros` compiles a standalone binary from
the exact dependency versions pinned in `qlfile.lock`. The result
runs directly, with no `qlot exec` wrapper needed at invocation time;
useful for CI steps that run the same script repeatedly, or for
distributing a built tool rather than the source scripts.

## Usage

The KV store works standalone, with no worker and no queue involved.
This is the default and most common way to use it: an embeddable
key/value store for any project, the same way you would reach for a
NoSQL library, not something that requires adopting a queue-processing
architecture to get value from.

```lisp
(bknr.hashkv:open-store)

(let ((key (bknr.hashkv:put-value "hello world")))
  (bknr.hashkv:get-value key)      ;=> "hello world"
  (bknr.hashkv:delete-value key))  ;=> T

(bknr.hashkv:close-store)
```

Caller-supplied keys and TTL, for named slots rather than
content-addressed blobs, still with no worker involved:

```lisp
(bknr.hashkv:put-keyed "session:abc123" "user-42" :expires-in-seconds 3600)
(bknr.hashkv:get-value "session:abc123")   ;=> "user-42" until it expires,
                                            ;   then NIL (lazy expiry)
```

Batch hashing parallelizes across the `lparallel` kernel directly,
also without a worker:

```lisp
(bknr.hashkv:batch-put '(1 2 3 "four"))
```

### Optional: the chanl request worker

For code that wants simple, serialized concurrent access without
managing its own locking, `start-worker`/`submit` route KV operations
through a single `chanl` worker thread. This is a convenience layered
on top of the plain API above, not a requirement for using the store:

```sh
qlot exec ./bknr.hashkv.ros
```

```lisp
(bknr.hashkv:open-store)
(bknr.hashkv:start-worker)

(let ((key (bknr.hashkv:submit :put "hello world")))
  (bknr.hashkv:submit :get key)      ;=> "hello world"
  (bknr.hashkv:submit :delete key))  ;=> T

(bknr.hashkv:stop-worker)
(bknr.hashkv:close-store)
```

### The persisted generic queue

A separate capability built on the same store, for the common case
where a project needs a work queue: FIFO by default, but with an
arbitrary payload and a claim/acknowledge cycle general enough to
support caller-built dependency ordering (a DAG of related entries)
on top, not something restricted to job-execution semantics.
Independent of the KV store and independent of the `chanl` request
worker above:

```lisp
(bknr.hashkv:enqueue '(:resize-thumbnail "media/abc.jpg"))

(multiple-value-bind (id payload) (bknr.hashkv:dequeue-claim "claimant-7")
  (when id
    (process payload)
    (bknr.hashkv:ack-claim id)))            ; success: remove it
    ;; or (bknr.hashkv:release-claim id)    ; failure: make it claimable again

;; Run periodically (e.g. from a cron-style task) to recover entries
;; whose claimant died mid-claim without acking or releasing:
(bknr.hashkv:reclaim-stale-claims :older-than-seconds 300)
```

## Testing

Three FiveAM/Gherkin suites are kept separate, matching the umbrella
system layout above:

```sh
qlot exec ./tests.ros   # unit: bknr.hashkv/tests, exercises
                         # PUT-VALUE/GET-VALUE and the rest of the
                         # KV/queue API directly, one behavior per test
```

```sh
qlot exec ./e2e.ros     # bknr.hashkv/e2e, exercises the worker
                         # lifecycle through submit rather than
                         # calling the store functions directly
```

`bknr.hashkv/e2e` includes a close-store/open-store cycle to guard
against a transaction log that looks correct while a process is
still running but does not survive a restart. Every suite
runs against scratch datastores under `/tmp/`, deleted and recreated
before each test.

### BDD (Gherkin, via sunny-side, no Ruby)

`features/bknr.hashkv.feature` is Gherkin, and it is the specification
that runs, rather than documentation sitting next to a
separately maintained test suite. `sunny-side`
(`denzuko/sunny-side`) is a standalone pure-Lisp Gherkin engine built
around a small hand-rolled parser
(Feature/Background/Scenario/Given-When-Then-And-But) that turns each
Scenario into an ordinary FiveAM test at compile time.
`features/step_definitions/steps.lisp` implements the step bodies
against `bknr.hashkv` using `fiveam:is`, the same assertion style
used throughout `t/test.lisp` and `t/e2e.lisp`.

```sh
qlot exec ./bdd.ros
```

This replaced an earlier version of this layer built on `clucumber`.
`antifuchs/clucumber` implements only the Lisp side of the Cucumber
*wire protocol*; something still has to parse `.feature` files and
drive that protocol over a socket, and that something is the Ruby
`cucumber` gem itself, not an optional add-on layered on top of it.
Depending on it meant pulling in a second language toolchain
(`Gemfile`, `bundle install`, the Ruby `cucumber` CLI) just to run
tests for a Lisp library, the same "no second thing to operate"
objection that ruled out Redis and Postgres for the store itself.
The trade-off in moving away from it: `sunny-side`'s parser only
covers the Gherkin subset in use here, with no `Scenario Outline`/
`Examples` tables, no data tables, no doc strings, and no tags
supported. That is a real limit on what this project's own
`.feature` files can express, but it is a scoped and extendable one
rather than one imposed from outside the project.

`sunny-side` began as inline code in this project
(`src/gherkin.lisp`) and was pulled out into its own repository once
it became clear the engine was not specific to `bknr.hashkv`. Nothing
in it touches `bknr.datastore` or anything else defined here.
`bknr.hashkv` remains its reference consumer, not a special case
built around its needs alone.

Every suite listed above, including this one, has been run to
completion against a real SBCL and Quicklisp install rather than left
as a written-but-unexecuted test file: `bknr.hashkv/tests` at
nineteen checks, `bknr.hashkv/e2e` at twelve, and `bknr.hashkv/bdd`
at six, all passing.

## Documentation

```sh
qlot exec ./docs.ros
```

This renders `@BKNR.HASHKV-MANUAL`, defined in `src/docs.lisp`,
through `40ants-doc`. The keyword arguments `40ants-doc:document`
accepts have changed across that library's history, so confirming
the current signature locally before wiring this into a CI pipeline
is worth doing first.

## License

BSD 3-Clause. See `LICENSE`.
