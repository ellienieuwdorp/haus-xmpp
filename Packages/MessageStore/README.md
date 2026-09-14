# MessageStore

First development persistence layer using Apple's system SQLite, with no downloaded dependencies. A `MessageStore` actor serializes its connection; SQLite transactions enforce insertion and reject conflicting identities. Chats and messages are scoped to an account. Reopening the database preserves messages, local stars and chat pins.

Create a protected directory before initializing `MessageStore(url:)`. Upsert a chat before inserting messages. `StoredMessage.id` is an application-generated stable identifier unique within an account. Never pass an arbitrary peer stanza ID as that identity: transport deduplication still needs validated issuer, conversation and identifier aliases. Duplicate inserts preserve local starring; different immutable content under the same identity throws `conflictingIdentity`.

`messages` returns the latest bounded page in chronological order, using timestamp plus ID for pagination. `search` performs literal substring matching with SQLite's ASCII case folding, with account and optional chat filtering. It is an initial query API, not the planned ranked, multilingual full-text search. Pins and stars are local only.

This is a **plaintext development database**. It does not implement database encryption, protected-key lifecycle, an outbox, receipts, protocol archive checkpoints, OMEMO persistence, multi-process crypto ownership or notification recovery. WAL sidecars also contain message data. The application owns directory protection and must not use this initial store for production private conversations. Schema version 1 refuses future versions rather than mutating an unknown schema.

Run `swift test --package-path Packages/MessageStore` from the repository root. Tests cover reopening, account isolation, duplicate/conflicting inserts, literal search, pagination ties and transaction rollback after a foreign-key failure.
