# OMEMO business logic

This package owns encrypted direct messaging policy and orchestration. It is independent of SwiftUI/UIKit, Keychain APIs, sockets and any hosted service. It depends on three focused packages: `OMEMOCrypto` for vetted cryptography, `XMPPProtocol` for typed wire values and the transport adapter, and `MessageStore` for atomic persistence.

`OMEMOService` coordinates device discovery, explicit fingerprint trust, profile selection, encrypted outbox preparation, incoming authentication, replay suppression and key-exchange acknowledgments. `StateProtection` accepts a device-local wrapping key supplied by the app. A mock `OMEMOTransport` runs the same logic in tests; the real adapter uses our own XMPP implementation.

The separation is intentional: business policy can be tested without a simulator, crypto can be checked against independent implementations, and the database can prove rollback without coupling either layer to a view. The notification extension can eventually reuse this code, but sharing a package does **not** establish extension ownership, entitlements or lifecycle correctness.

## Durable contract

1. Save a message intention as queued before clearing the composer. It is not yet sent.
2. Refresh each contact's device sets and public bundles. New/changed identities require an explicit decision; a blocked device is deliberately excluded. Other contacts continue independently.
3. Load an ephemeral engine from the account-bound, encrypted state snapshot. Encrypt for approved peer devices and other approved devices of the sender. Both protocol profiles share one identity pair, with separate prekeys/sessions.
4. Commit the updated ratchets, exact encrypted envelope, selected fingerprint set and message security state in one SQLite transaction using a revision comparison.
5. Give the sender a finite set of successfully prepared message IDs. Messages queued during preparation wait for the next pass. Revalidate local trust immediately before handing out ciphertext.
6. A retry reuses the saved envelope and stable stanza ID. If recipients changed, do not regenerate the original message's ciphertext or silently omit a new device.

Incoming ciphertext is retained before network key discovery or user trust decisions. Replay identity uses the ciphertext for **this** device plus profile, sender device, IV and payload, scoped by account and sender; outer IDs and unrelated recipient-key ordering do not alter that identity. Authentication, ratchet advancement, message insertion, replay outcome and any empty key-exchange response commit together. Failed transactions discard mutated engines. One invalid pending message cannot prevent processing other pending messages.

Swift actors serialize in-process work. SQLite revision checks reject stale commits from another coordinator; they are not a complete main-app/notification-extension ownership solution. The current app remains the sole process owning outbox transport.

## Profiles and trust

- Legacy OMEMO encrypts body text, including quoted fallback text. It does not expose private reply metadata in outer XML.
- OMEMO 2 encrypts a bounded SCE envelope and verifies present sender/recipient affixes. Body/reply extensions are interpreted within that authenticated context. Group messages are not supported by this direct-message API.
- An established outgoing profile never changes because an incoming message used another profile. Prepared ciphertext retains its original profile.
- Devices advertised only in another profile block sending instead of being silently omitted. Numeric IDs alone cannot prove a physical device's identity; exact fingerprint approval remains necessary within each profile.
- Fingerprints use the interoperable 32-byte Curve25519 representation; trust remains bound to the complete wire identity, account, profile and device ID.
- “Accepted” means encryption is allowed without independent verification. “Verified” records the user's out-of-band comparison. An A→B→A key change requires review again. Temporarily absent devices retain history.
- Existing inconsistent prototype identities fail closed. They are never silently replaced to make a test pass.

## Validation

```sh
swift test --package-path Packages/OMEMO
```

See `Scripts/Interop/README.md` for independent upstream Python ratchet/payload checks and live local-peer testing. `omemo-lab` is a separate test executable, excluded from the iOS app product. It requires explicit fixture-trust authorization and generated localhost accounts; its automatic test trust policy is never used by the application.

The [milestone report](../../docs/development/omemo-milestone.md) records verified capabilities and remaining release work. This is a development direct-messaging milestone, not a claim of full production OMEMO support across groups, archives, devices and notifications.
