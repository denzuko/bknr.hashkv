# bknr.hashkv architecture

Diagrams describe version 1.1.0 on the `develop` branch.

## Components

`bknr.hashkv` runs in the caller's process. Every write passes through
a `bknr.datastore` transaction, which the store's guard serialises.

```mermaid
flowchart TB
  caller["Calling code"]
  subgraph hashkv["bknr.hashkv"]
    kv["Key/value API<br/>put-value, put-keyed, get-value,<br/>delete-value, batch-put"]
    queue["Queue API<br/>enqueue, dequeue-claim, ack-claim,<br/>release-claim, reclaim-stale-claims"]
    worker["Optional worker<br/>start-worker, submit, stop-worker"]
    value["Value layer<br/>stored-form, value-from-form<br/>(copies; instances as slot lists)"]
    store["hashkv-store<br/>(mp-store subclass; holds the worker)"]
  end
  ttl["bknr.ttl<br/>timestamped-entry, sweep-expired"]
  ds["bknr.datastore<br/>(denzuko fork)<br/>snapshot + transaction log"]
  idx["bknr.indices<br/>string-unique-index on key and token-id"]
  crypto["ironclad + babel<br/>SHA-256 keys, OS PRNG token ids"]
  lp["lparallel<br/>batch conversion and hashing"]
  ch["chanl<br/>worker task and channels"]
  mop["closer-mop<br/>class slots"]

  caller --> kv
  caller --> queue
  caller --> worker
  worker --> kv
  worker --> ch
  kv --> value
  queue --> value
  value --> mop
  kv --> crypto
  kv --> lp
  queue --> crypto
  kv --> store
  queue --> store
  store --> ds
  ds --> idx
  kv --> ttl
  queue --> ttl
```

## Key/value write path

The value is converted to its stored form before the transaction: a
fresh copy made only of types the transaction log can write, with class
instances as slot lists. The lookup that decides between creating and
updating an entry runs inside the same transaction as the write. A
concurrent put of the same value therefore finds the entry the first
put created, and no transaction fails on the unique index. Reads return
a copy rebuilt from the stored form.

```mermaid
sequenceDiagram
  participant C as Caller
  participant P as put-value / put-keyed
  participant V as stored-form
  participant S as store-entry
  participant G as Store guard (with-transaction)
  participant I as Key index

  C->>P: value [, key], expires-in-seconds
  P->>V: value
  alt storable
    V-->>P: fresh stored form
  else function, stream, cycle, ...
    V-->>C: unstorable-value-error
  end
  alt put-value
    P->>P: key = SHA-256 of stored form, standard syntax
  else put-keyed
    P->>P: reject 64-hex keys (reserved-key-error)
  end
  P->>S: key, stored form, expiry
  S->>G: acquire
  G->>I: entry-with-key key
  alt entry exists
    G->>G: set value and expires-at
  else no entry
    G->>G: make-instance kv-entry
  end
  G-->>S: release, logged
  S-->>C: key
```

## Queue entry lifecycle

Order among claimable entries is the store object id, which the store
allocates in transaction order.

```mermaid
stateDiagram-v2
  [*] --> Unclaimed: enqueue
  Unclaimed --> Claimed: dequeue-claim (earliest claimable)
  Claimed --> Unclaimed: release-claim
  Claimed --> Unclaimed: reclaim-stale-claims (claim older than limit)
  Claimed --> [*]: ack-claim
  Unclaimed --> Expired: expires-at reached
  Expired --> [*]: sweep-expired
  Claimed --> [*]: sweep-expired (expires-at reached)
  note right of Expired
    Expired entries are never
    returned by dequeue-claim.
  end note
```

## Worker request flow

The worker is attached to the open store. An operation's error is
returned to the caller and signalled there; the worker keeps running.

```mermaid
sequenceDiagram
  participant C as Caller thread
  participant W as Worker task (chanl)
  participant K as Key/value API

  C->>C: start-worker (attach to hashkv-store)
  C->>W: request (op, arg, reply channel)
  W->>K: apply op
  alt operation returns
    K-->>W: result
    W-->>C: (:ok . result)
    C->>C: return result
  else operation signals
    K-->>W: condition
    W-->>C: (:error . condition)
    C->>C: signal condition
  end
  C->>W: stop-worker (NIL request, under worker lock)
  W-->>C: stopped notice
  Note over C,W: close-store also stops the worker
```
