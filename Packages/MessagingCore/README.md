# MessagingCore

Application-owned coordination across MessageStore, XMPPProtocol and OMEMO. `OutboxSender` serializes prepared send claims. `StreamPersistence` binds one immutable account to revisioned stream state, atomic server acceptance and encryption replay authorization. `ArchiveSynchronizer` orders ciphertext/message commits before archive checkpoints and inbound acknowledgements; abandoned pages disconnect safely.

Acquire the store transport lease before running send/recovery operations. Cancellation before transport returns a claim to queue; a completed or uncertain socket write is unconfirmed unless an authenticated server acknowledgement has already advanced it. Stale callbacks cannot regress server acceptance. Exact-ciphertext retry policy remains separate from recipient delivery.

`swift test --package-path Packages/MessagingCore` covers sender ordering, cancellation, account/revision fences, corrupt snapshots and refusal to resume plaintext or unknown encrypted operations. Protocol and OMEMO packages add live server and cryptographic interoperability checks.
