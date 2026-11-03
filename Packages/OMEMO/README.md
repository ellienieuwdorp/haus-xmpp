# OMEMO

Encrypted messaging policy: device discovery, fingerprint trust, profile selection, sealing the outbox, authenticating incoming ciphertext, replay suppression and recovery. It has no UI, Keychain, socket or hosted-service code. It builds on `OMEMOCrypto` (vetted cryptography), `XMPPProtocol` (typed wire values and the transport) and `MessageStore` (atomic persistence). Private groups are described in [GROUPS.md](GROUPS.md), reactions in [REACTIONS.md](REACTIONS.md).

## Public surface

- `OMEMOService`: the actor every operation goes through. Direct chats: `initialize`, `refreshDevices`, `overview`, `setTrust`, `prepareAvailableMessages`, `outgoingEnvelope`, `receive`, `retryPendingIncoming`, `hasDurableIncomingDisposition`, `canReplay`, `reconcileArchivedOutgoing`. Updates: `queueReactions`, `queueRetraction`, `queueCorrection`, `queueReceipt`, `prepareAvailableUpdates`, `flushUpdates`, and the `receivePlaintext…` entry points for legacy peers. Own devices: `ownDevices`, `refreshOwnDevices`, `retireOwnDevice`, `maintainLocalAdvertisement`, `repairSession`. Key loss: `unreadableStates`, `startOver`.
- `OMEMOTransport` and `OMEMOGroupTransport`: the network the service needs; `XMPPClient` conforms, tests use an in-memory server.
- `StateProtection`: AES-GCM over the state blob with the account as associated data, keyed by a device-local key the app supplies.
- `EncryptionDevice`, `DeviceTrust`, `EncryptionOverview`, `OMEMOError` (user-facing descriptions included), `AttachmentTransfer`.

## Guarantees

1. A message is saved as a queued intention before encryption; it is not sent yet.
2. Each operation loads an ephemeral engine from the account-bound state snapshot and commits the advanced ratchets, the exact envelope, the recipient fingerprint set and the message state in one SQLite transaction with a revision check. A failed operation discards the engine; it never advances durable ratchets. No network call runs inside a transaction.
3. The sender may claim only the returned set of prepared IDs; messages queued meanwhile wait for the next pass. Trust is revalidated before ciphertext is handed out. A retry reuses the saved envelope and stanza ID; if the recipients changed it fails with `recipientSetChanged` rather than regenerating ciphertext or silently omitting a device.
4. Incoming ciphertext from an unknown or unapproved device is retained before any key fetch or trust wait. Replay identity is the ciphertext addressed to this device plus profile, sender device, IV and payload, scoped by account and sender; outer IDs never change it. Authentication, ratchet advancement, the stored message, the replay outcome and any key-exchange answer commit together. One bad pending message never blocks the others.
5. A stream or archive acknowledgement is safe only when `hasDurableIncomingDisposition` (or `hasDurableGroupDisposition`) is true. A storage failure leaves nothing durable, so the caller must not acknowledge.
6. Retained ciphertext is not authenticated content: `pendingConversations` exposes only addresses and counts. A `sentAt` passed to `receive` must come from a validated archive or delivery context; it can correct a retained arrival time, and only for the exact same envelope and conversation.
7. Swift actors serialize in-process work. Revision checks reject stale commits from another process sharing the database (the notification extension); transport ownership is the `MessageStore` lease.

## Profiles and trust

- Legacy OMEMO (`eu.siacs.conversations.axolotl`) encrypts the body only. OMEMO 2 (`urn:xmpp:omemo:2`) encrypts a bounded XEP-0420 SCE envelope and checks the sender and recipient affixes it carries.
- Both profiles share one identity pair per device ID, with separate prekeys and sessions. State whose profiles disagree on the identity fails closed and is never repaired by replacing an identity.
- A chat's profile is chosen once and never silently downgraded; prepared ciphertext keeps its profile. In a direct chat, a device published only in the other profile is never encrypted to: it is left out of the envelope and reported through `EncryptionOverview`. In a room it fails discovery with `unsupportedProfile`.
- Fingerprints are the 32-byte Curve25519 form; trust is bound to the full identity key, owner, profile and device ID. New or changed keys are `.undecided` until the user decides. Accepted means encryption is allowed; verified records an out-of-band comparison. A key that returns (A→B→A) needs review again.
- A rejected device is excluded from sends; its incoming ciphertext is never opened and becomes a quiet placeholder.
- Session repair rebuilds only the selected fingerprint's session and keeps the old one for delayed messages. Retiring an own device rereads the lists, checks the fingerprint in every profile before changing anything, and cannot wipe or stop the remote installation.
- `startOver` replaces an identity only with explicit confirmation, only for state the current key cannot open, and never reuses a retired device ID.

## Testing

```sh
swift test --package-path Packages/OMEMO
```

Tests await teardown and close every SQLite connection before deleting fixture files; never remove a database directory in a synchronous `defer` while a service still holds its store. The `*LabTests` suites skip unless their `HAUS_LAB_*` variables are set. `omemo-lab` refuses anything but generated localhost fixture accounts and an explicit trust flag. Their automatic trust is harness policy, never the app's.
