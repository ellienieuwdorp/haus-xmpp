# MessageStore

Account-scoped persistence for messages, chats, encryption state and transport work, on Apple's system SQLite with no downloaded dependencies. The `MessageStore` actor serializes one connection; every multi-row change is one SQLite transaction.

The database holds plaintext messages and serialized OMEMO state under OS file protection, not database-level encryption; WAL sidecars hold the same data. The app owns the protected directory, backup exclusion, account and key lifecycle, and notification coordination.

## Public surface

- **Messages and chats**: `upsertChat`, `insertMessage`, `messages` (latest bounded page, chronological, paged by timestamp plus ID), `chats` (the chat list in one statement), `search` (literal substring, SQLite ASCII case folding). `StoredMessage.id` is an application-generated identity unique within an account, never a peer stanza ID. A duplicate insert keeps local stars; different content under the same ID throws `conflictingIdentity`. Pins and stars are local only.
- **Outbox**: `enqueueOutgoing`, `claimNextOutgoing`, `finishOutgoingSubmission`, `releaseUnsentSubmission`, `recoverInterruptedSubmissions`, `retryOutgoing`, `failQueuedOutgoing`, `rejectOutgoing`; the same lifecycle for non-message stanzas (reactions, receipts, markers, retractions, corrections, key transports) through `enqueueReceipt`, `enqueueMessageUpdate`, `sealQueuedUpdate` and `claimNextUpdate`.
- **Transport lease**: `acquireTransportOwnership`, `releaseTransportOwnership`, `holdsTransportOwnership`.
- **Encryption**: `saveEncryptionState`, `sealQueuedOutgoing`, `commitEncryptedIncoming`, `retainEncryptedIncoming`, `recordUnreadableMessage`, `resetEncryption`.
- **Synchronization**: `saveStreamManagement`, `reconcileArchivedOutgoing`, `saveArchiveCheckpoint`, `saveNewestArchivePage`, `saveArchiveBackfillCursor`.
- **Read state and notifications**: `markRead`, `applyDisplayedSync`, `unreadCounts`, `pendingNotifications`, `removeNotificationCandidates`.
- **Lifecycle**: `close`, `closeForMigration`, `writeSnapshot`, `upgradeSchema`, and `SchemaAccess` (`upgrade`, `currentOnly`, `asIs`).

## Invariants

- **Lease before transport work.** Claiming, finishing, retrying and recovering outgoing work require `acquireTransportOwnership()`: a nonblocking kernel `flock` on a database sidecar shared by the app and its extensions. A suspended process keeps the lock; contenders get `transportOwnedElsewhere`; process death releases it, with no timeout. Opening a store never changes another owner's active claim. Stop and join every sender before releasing; release invalidates attempt tokens. Never remove the lock sidecar.
- **Socket completion is not delivery.** A finished submission, success or error, becomes `unconfirmed`. Only an authenticated stream acknowledgement (`saveStreamManagement`, which also stores the protocol's opaque snapshot) or an exact-ciphertext own-archive match (`reconcileArchivedOutgoing`) marks it `serverAccepted`, which late callbacks, recovery and retries cannot regress. Server acceptance is not peer delivery or reading.
- **Retries resend exact bytes.** `retryOutgoing` reuses the stable wire ID and the saved ciphertext; the UI warns about possible remote duplicates. Release and completion calls are fenced by the attempt token, so a stale callback cannot change a later attempt.
- **Ciphertext, state and outcome commit together.** `sealQueuedOutgoing` stores exact ciphertext with the ratchet advance; `commitEncryptedIncoming` stores the authenticated message, replay outcome, session change and any response together. Encryption state is revision-checked: a conflict means the caller discards its in-memory engine and reloads. Crypto writes need no transport lease.
- **Archive page before checkpoint.** Advance a MAM checkpoint only after the whole page is durably handled; revision checks reject stale page completions, and replay after a crash is deduplicated by the message and crypto pipeline.
- **Reactions.** Authenticated (SCE) reactions resolve only through a wire ID that identifies exactly one message in the conversation; an ambiguous ID resolves to nothing. Each actor's newest `(updatedAt, id)` event is their complete set, an empty set withdraws, and a reused event ID cannot replace its first contents. Events for missing targets are kept until the target arrives. Reaction updates have their own outbox and never create message rows.
- **Schema.** Opening with `.upgrade` migrates in place; `.currentOnly` refuses an older store before writing; an unknown newer schema is always refused.
- **Every table is an `AccountTable`.** Each is keyed by `account_id` and declares what a transfer (`removeDeviceLocalRows`) and sign-out (`removeRowsAtSignOut`) do to it; erasing an account and a snapshot cover every table. A migration that adds a table without a case, or without a row in `Fixtures/account-tables.sql`, fails `AccountTablePolicyTests`.
- **Close before deleting.** Stop and join all work and `try await store.close()` on every connection before deleting or replacing a database, its WAL or SHM. `close` is idempotent; later calls throw `MessageStoreError.closed`.

## Testing

```sh
swift test --package-path Packages/MessageStore
```

The suite covers subprocess lock contention and SIGKILL recovery, acknowledgement races, archive and checkpoint revision checks, migrations from real earlier-schema stores, account isolation, duplicate and conflicting inserts, outbox fencing, reaction projection and the chat-list query against a reference built from public API.
