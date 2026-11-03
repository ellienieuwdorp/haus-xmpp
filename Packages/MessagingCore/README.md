# MessagingCore

Coordination across MessageStore, XMPPProtocol and OMEMO, shared by the app, its notification extension and its share extension.

## Public surface

- `OutboxSender`, `OutboxDrain`, `OutgoingEnqueue`: the durable outgoing path. Enqueue needs no transport lease; the drain seals and sends under it.
- `InboundProcessor`, `StreamPersistence`: inbound persistence and stream-management resumption for one account.
- `ArchiveSynchronizer`, `ReadSync`: own-account and room archive catch-up, backfill, and XEP-0490 read state.
- `BackgroundSynchronizer`, `ShareSession`, `LivenessHandshake`: bounded work in the extensions.
- `NotificationPlanner`, `NotificationPresenter`, `NotificationIdentity`, `CommunicationNotification`, `CommunicationPerson`, `OutgoingDonation`: local notifications, communication intents and share suggestions.
- `LifecycleSignals`, `LifecycleTransition`, `SceneLifecycleDriver`, `MacLifecycleDriver`, `AttentionRules`: pure lifecycle policy for iOS and the Mac.
- `TransferArchive`, `TransferCode`: the encrypted install-to-install transfer file.
- `PushSubscription`, `PushRegistrationJournal`: push gateway subscription and registration intent.

## Invariants

- Send and recovery run only under the store's transport lease. Extensions wait for it for a bounded time and never steal or expire it.
- A completed socket write is unconfirmed. Only an authenticated stream-management acknowledgement marks a message as accepted by the server, and a stale callback cannot regress it. Cancellation returns a claim to the queue only before the transport was invoked.
- Retries send the exact saved ciphertext; nothing that may have been sent is regenerated. Resumption replays only journal entries that are exactly one durable outgoing row; anything else binds fresh.
- An inbound stanza is durably disposed (stored, retained ciphertext, placeholder or rejection) before the stream-management barrier after it is acknowledged. Otherwise the barrier is refused and the stream ends.
- An archive page's message and pending-ciphertext commits precede its checkpoint, which precedes the page's acknowledgement. On any error or cancellation inside a page the connection is closed, so no unhandled token gap remains on a live stream.
- A room refusal or membership error ends only that room's walk and leaves its checkpoint unchanged. Malformed responses, storage failures and transport failures abort and disconnect. Room catch-up never joins rooms or approves fingerprints, and a nickname alone never authenticates a sender.
- Unverifiable or unsupported encrypted content gets a content-free rejection record or placeholder and is never shown as authenticated text. Plaintext is never sent and never shown as authenticated.
- Notifications carry opaque, account-scoped identifiers only. A notification run that cannot settle shows the generic fallback, never a suppressed alert. With previews off no name, avatar or contact reaches the system.

## Tests

```sh
swift test --package-path Packages/MessagingCore
```

The suite is deterministic and needs no server. Tests whose names end in `LabTests` run against a local Prosody only when their `HAUS_LAB_*` environment variables are set, and are skipped otherwise.
