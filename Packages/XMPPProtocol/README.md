# XMPPProtocol

An XMPP client stack in Swift: transport, stream management, archive recovery and the wire formats for OMEMO, groups, reactions, receipts, files and push. It uses Foundation's XML parser, Network.framework, Security.framework and CryptoKit, with no external package dependencies. It carries typed ciphertext but performs no OMEMO cryptography or trust decisions; those belong to the OMEMO packages.

## Public surface

- `XMPPClient` (actor): `connect` through SRV discovery (`.discover`) or a fixed endpoint, `disconnect` / `disconnectAndWait`, and a single-consumer `events` stream of `XMPPEvent`.
- Sending: `sendMessage`, `sendEncryptedMessage`, `sendEncryptedGroupMessage`, `sendReaction`, `sendRetraction`, `sendReceipt`, `sendChatState`; preflight with `messageProblem` / `validateMessage`; pure encoders such as `encryptedMessageXML` for persisting exact bytes before a write.
- Recovery: `configureStreamManagement(persistence:)` with an `XMPPStreamManagementPersistence` adapter, `acknowledgeInbound`, `fetchArchivePage(_:limit:room:)`, `probeLiveness(within:)`.
- Presence and state: `setAvailability`, `setClientActive`, `fetchRoster`, `sendSubscription`, `lastActivity`, `fetchBlocklist`, `block`, `unblock`, `fetchDisplayedSync`, `publishDisplayedSync`.
- OMEMO PEP: `fetchOMEMODevices`, `fetchOMEMOBundle`, `publishOMEMODevices`, `publishOMEMOBundle` for both `XMPPOMEMOProfile` values (legacy `eu.siacs.conversations.axolotl` and `urn:xmpp:omemo:2`).
- Groups: `joinGroupRoom`, `leaveGroupRoom`, `refreshGroupRoom`, `groupRoomSnapshot`.
- Push and uploads: `enablePush`, `disablePush`, `updatePushRegistration`, `uploadService`, `requestUploadSlot`.
- Value types: `JID` (RFC 7622 normal form), `MessageContent` (payload grammar shared by plain stanzas and SCE `<content>`), `FileSharing`, `LinkMetadata`, `LinkDetection`, `EntityCapabilities`.

## Guarantees

- Every mechanism runs inside validated TLS (direct TLS or mandatory STARTTLS, TLS 1.2 or later). Certificates are checked against the account domain, never the transport host. `XMPPClient(labCertificateAuthority:)` restricts trust to one DER CA for local test servers; there is no accept-all path.
- SASL: SCRAM-SHA-256, SCRAM-SHA-1, then PLAIN. PLAIN is refused when the caller passes `requireSCRAM`, as the app does once an account has authenticated with SCRAM; a SCRAM success without a valid server signature fails the login.
- The server binds the resource, never the account: a bind for another bare JID ends the session.
- `sendMessage` sends plaintext for tests and lab tools; it is never a fallback for an encrypted chat.
- A completed send means the local socket accepted the bytes. A XEP-0198 acknowledgement means server acceptance only, never recipient delivery.
- Every counted outbound stanza is journaled before its socket write. Resumption replays only the exact saved bytes, and only after `permitsResumption` approves the snapshot; encrypted applications must override it to revalidate recipient trust. A refused resume never retransmits.
- An inbound message that produced events is followed by `.streamManagementBarrier(token)`. The advertised `h` never exceeds the persisted handled count, which advances only after the consumer acknowledges contiguous tokens.
- Archive pages carry `handledTokens`: persist every result and the cursor before acknowledging them. A partial page that fails disconnects, so no acknowledgement gap stays on a live connection.
- Only own-account wrappers are unwrapped (carbons from our bare JID, MAM results from our archive); foreign or nested wrappers are discarded whole. Recognized OMEMO content never falls back to its plaintext body.
- Unencrypted reactions, receipts and retractions exist for legacy-OMEMO peers; their actor is server-authenticated only.
- Group membership comes from the room's affiliation lists, never from occupant presence. A first validation needs two agreeing reads.
- Parser and resource limits: 1 MiB per stanza, 16 element levels in decrypted payloads, 512 devices, 1,024 recipient keys, 2,000 replayable journal entries (4 MiB), 200 archive results per page.

## Testing

```sh
swift test --package-path Packages/XMPPProtocol
```

The unit suites use an in-process `LoopbackServer` and cover framing, parsing limits, authentication, stream management and resumption, archive validation and the wire codecs. Suites named `*LabTests` run only when their `HAUS_LAB_*` environment variables point at disposable accounts on a test server you control.

The `haus-lab` executable runs the same checks against a live server. It reads credentials only from the environment (`HAUS_LAB_DOMAIN`, `HAUS_LAB_USERNAME`, `HAUS_LAB_PASSWORD`, optional `HAUS_LAB_HOST`, `HAUS_LAB_PORT`, `HAUS_LAB_CA_DER`) and prints states, IDs and byte counts, never bodies or passwords. Further `HAUS_LAB_*_SMOKE` variables enable the recovery, OMEMO wire, carbons, reply, push and blocking checks. Its OMEMO check uses synthetic keys: it proves PEP and envelope transport, not cryptographic interoperability.
