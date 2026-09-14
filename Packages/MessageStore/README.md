# MessageStore

First development persistence layer using Apple's system SQLite, with no downloaded dependencies. A `MessageStore` actor serializes its connection; SQLite transactions enforce insertion and reject conflicting identities. Chats and messages are scoped to an account. Reopening the database preserves messages, local stars and chat pins.

Create a protected directory before initializing `MessageStore(url:)`. Upsert a chat before inserting messages. `StoredMessage.id` is an application-generated stable identifier unique within an account. Never pass an arbitrary peer stanza ID as that identity: transport deduplication still needs validated issuer, conversation and identifier aliases. Duplicate inserts preserve local starring; different immutable content under the same identity throws `conflictingIdentity`.

`messages` returns the latest bounded page in chronological order, using timestamp plus ID for pagination. `search` performs literal substring matching with SQLite's ASCII case folding, with account and optional chat filtering. It is an initial query API, not the planned ranked, multilingual full-text search. Pins and stars are local only.

This is a **plaintext development database**. It does not implement database encryption, protected-key lifecycle, receipts, protocol archive checkpoints, OMEMO persistence, multi-process crypto ownership or notification recovery. WAL sidecars also contain message data. The application owns directory protection and must not use this initial store for production private conversations. Schema version 2 refuses future versions rather than mutating an unknown schema.

Run `swift test --package-path Packages/MessageStore` from the repository root. Tests cover reopening, account isolation, duplicate/conflicting inserts, literal search, pagination ties, transaction rollback, version-1 migration, durable FIFO work, interrupted submissions, explicit retry and stale callback fencing.

## Durable outbox

`enqueueOutgoing` atomically inserts a local outgoing message and queued work. Use its application-generated `message.id` as the wire stanza/origin ID; repeating enqueue is idempotent and never resets an attempt. Existing messages without an outbox record are not automatically replayed during migration or enqueue.

`claimNextOutgoing(accountID:)` claims FIFO work and returns a persisted attempt token. After calling the socket sender, invoke `finishOutgoingSubmission` for either success or error: both become **unconfirmed**, since socket completion does not prove remote acceptance and an error can occur after writing. Interrupted claims become unconfirmed on store open. Only queued work is selected automatically. Explicit `retryOutgoing` reuses the same stable wire ID; the UI must warn about possible remote duplicates. `failQueuedOutgoing` is restricted to pre-send local rejection.

If disconnected/cancelled before invoking the socket operation, `releaseUnsentSubmission` may safely return the claim to queued. Once the send is invoked, use unconfirmed instead. Release/completion calls are fenced by the attempt token so stale callbacks after recovery/retry cannot change a later attempt. Cancellation before claim leaves work queued; cancellation after claim requires the caller to finish/release according to this rule.

Maintain **one store owner and one account sender** for each database. Opening a second store recovers in-flight work and is not a supported way to coordinate multiple processes. Explicit account recovery must occur only after stopping and joining its sender. This outbox is a foundation for future stream management and receipts, not exactly-once delivery or notification-extension ownership.
