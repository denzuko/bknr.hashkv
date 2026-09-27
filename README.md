# bknr.hashkv

bknr.hashkv is a Common Lisp library that provides a content-addressed
key/value store and a persisted work queue over `bknr.datastore`. Both
structures share one store, and entries in either may carry an expiry
through `bknr.ttl`. The library runs inside the calling process; it has
no server, no network protocol and no replication.

Architecture diagrams are in [docs/architecture.md](docs/architecture.md).

## Installation

bknr.hashkv, bknr.ttl and the maintained bknr-datastore fork are not in
the Quicklisp distribution. qlot does not resolve the git dependencies
of a git dependency, so a consuming project lists all three in its own
`qlfile`:

```
git bknr.hashkv https://github.com/denzuko/bknr.hashkv.git :branch develop
git bknr.ttl https://github.com/denzuko/bknr.ttl.git :branch develop
git bknr-datastore https://github.com/denzuko/bknr-datastore.git :branch develop
```

```sh
qlot install
```

## Usage

### Store

`open-store` opens or creates a store and must precede every other
call. With no argument it uses `bknr.hashkv/` under the XDG data
directory. `close-store` stops the store's worker, if one is running,
and closes the store.

```lisp
(bknr.hashkv:open-store #p"/var/lib/example/store/")
(bknr.hashkv:close-store)
```

### Content-addressed values

`put-value` stores a value under the SHA-256 of its readable printed
form and returns that key. The key does not depend on the caller's
printer settings or current package. Values without a readable printed
form, such as most CLOS instances, signal `print-not-readable`.

```lisp
(let ((key (bknr.hashkv:put-value "hello world")))
  (bknr.hashkv:get-value key)      ;=> "hello world"
  (bknr.hashkv:delete-value key))  ;=> T
```

Storing a value that is already present returns the same key and
replaces the entry's expiry with the one given, so a second
`put-value` renews an entry.

### Named keys

`put-keyed` stores a value under a caller-supplied string. A key of 64
lowercase hexadecimal digits has the form of a content key and signals
`reserved-key-error`, so a named write cannot replace a
content-addressed value.

```lisp
(bknr.hashkv:put-keyed "session:abc123" "user-42" :expires-in-seconds 3600)
(bknr.hashkv:get-value "session:abc123")  ;=> "user-42", NIL after expiry
```

### Expiry

`:expires-in-seconds` sets an expiry relative to the time of the call.
`NIL` means no expiry; `0` or a negative number expires the entry at
once. `get-value` deletes an expired entry when it reads one.
`sweep-expired` deletes every expired key/value and queue entry and
returns the count.

### Batches

`batch-put` hashes a list of values in parallel with lparallel and
stores them in order, one transaction per value. It uses the caller's
`lparallel:*kernel*` when one is bound and otherwise creates a kernel
for the call. A batch is not atomic: an error leaves earlier values
stored.

```lisp
(bknr.hashkv:batch-put '(1 2 3 "four") :expires-in-seconds 600)
```

### Queue

`enqueue` adds a payload and returns a random 128-bit token id.
Identical payloads become separate entries. `dequeue-claim` claims the
earliest claimable entry in one transaction, so two claimants never
receive the same entry. `ack-claim` deletes a finished entry and
`release-claim` returns it to the queue. `reclaim-stale-claims`
releases claims older than a given age, for claimants that stopped
without doing either.

```lisp
(bknr.hashkv:enqueue '(:resize-thumbnail "media/abc.jpg"))

(multiple-value-bind (token payload) (bknr.hashkv:dequeue-claim "claimant-7")
  (when token
    (process payload)
    (bknr.hashkv:ack-claim token)))

(bknr.hashkv:reclaim-stale-claims :older-than-seconds 300)
```

`dequeue-claim` and `reclaim-stale-claims` scan every queue entry, so
their cost grows with the number of entries. On one SBCL 2.6.8 process,
a claim followed by its release took 0.48 ms with 1,000 entries queued
and 3.16 ms with 10,000.

### Worker

The worker is optional. It applies `:put`, `:get` and `:delete`
requests one at a time on its own thread, for callers that prefer a
single serialised path to the store. It is unrelated to the persisted
queue. An error raised by an operation is signalled again in the
calling thread and the worker continues.

```lisp
(bknr.hashkv:start-worker)
(let ((key (bknr.hashkv:submit :put "hello world")))
  (bknr.hashkv:submit :get key))  ;=> "hello world"
(bknr.hashkv:stop-worker)
```

## Scope

The library provides no publish/subscribe, network protocol, eviction
policy or replication. Its purpose is an embedded store and queue that
other projects take as a library dependency on the same persistence
layer, `bknr.datastore`.

## Development

```sh
qlot install
./bknr.hashkv.ros bdd     # Gherkin features through sunny-side
./bknr.hashkv.ros test    # unit suite
./bknr.hashkv.ros e2e     # worker lifecycle and restart persistence
./bknr.hashkv.ros docs    # render the manual to standard output
.github/scripts/gate.ros  # reader check, bare IF scan, docstring voice
.github/scripts/cover.ros # all suites; fails below 100% branch coverage
```

The scripts load `.qlot/setup.lisp` when it exists, so they run without
`qlot exec`.

## Licence

BSD 3-Clause. See `LICENSE`.
