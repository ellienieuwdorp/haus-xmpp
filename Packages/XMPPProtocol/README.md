# XMPPProtocol — transport and OMEMO wire

Owned Swift code, Foundation XMLParser, Network.framework and Security.framework; no external package dependencies. This is a deliberately limited direct-TLS client. It transports typed encrypted envelopes; cryptography and trust belong to the separate OMEMO packages. **This package alone is not an encrypted messenger or a production-ready XMPP stack.**

Implemented: account-domain certificate validation (separate from transport host), TLS 1.2 minimum, SASL PLAIN inside validated TLS, XML stream restart, resource binding, initial presence, ordinary direct chat text with caller-supplied stanza/origin IDs, XEP-0199 ping responses, bounded stanza parsing and event buffering. `connect` returns only after authentication and resource binding. A 20-second deadline bounds TLS and XMPP negotiation; cancellation/disconnect invalidates the session generation.

Also implemented: correlated IQ requests, service feature discovery, OMEMO PEP device lists/bundles, typed ciphertext send/receive, device-list events, and sent/received message carbons with strict wrapper provenance.

Not implemented: DNS SRV, STARTTLS, SCRAM/SASL2, complete JID preparation, cryptography, the persistence adapter itself, end-to-end delivery receipts, roster, rooms, reactions or media. A completed send means Network.framework accepted the bytes, **not** that the server stored or the recipient received the message. Incoming IDs are unverified server/peer fields, not globally unique database keys.

## API

```swift
let client = XMPPClient() // System trust; no user-keychain changes.
// Consume events in a separate task before connecting.
let eventTask = Task {
    for await event in client.events { /* state or incoming message */ }
}
try await client.connect(host: "server.example", domain: "example", username: "alice", password: password)
let id = try await client.sendMessage(to: "bob@example", body: "Explicit plaintext laboratory message", id: durableOutboxID)
await client.disconnect()
```

The optional `id` argument defaults to a UUID. Persist it before sending and preserve it on retries; it is emitted as both stanza `id` and an immediate XEP-0359 `origin-id` in `urn:xmpp:sid:0`. Identifiers must be nonempty, at most 1,024 UTF-8 bytes, valid XML text and contain no whitespace. `XMPPMessage.originID` preserves a single valid immediate origin ID separately from the sender stanza ID; neither is an authenticated globally unique identity. Nested, wrong-namespace and duplicate origin IDs are ignored. The application must scope any deduplication to the authenticated account, sender, conversation and processing provenance.

Outgoing lab messages also accept `reply: XMPPReply?` in `sendMessage` and `validateMessage`. The snapshot is limited to 16,384 UTF-8 bytes; the combined quoted fallback and user body remain limited to 65,536 bytes. `XMPPReply(id:to:body:)` uses an optional wire ID. A known ID emits `urn:xmpp:reply:0` metadata and `urn:xmpp:fallback:0` offsets. With `id: nil`, it emits only a visible quote, never a fabricated reference. Callers must keep local navigation IDs separate from wire IDs. Incoming reply resolution, capability advertisement and group replies are not implemented; this is outgoing serialization, not complete reply interoperability.

Source check, 2026-09-14: [XEP-0461 0.2.1](https://xmpp.org/extensions/xep-0461.html) specifies direct-chat origin-ID preference and reply metadata; [XEP-0428 0.2.1](https://xmpp.org/extensions/xep-0428.html) defines fallback ranges; [XEP-0426 0.3.0](https://xmpp.org/extensions/xep-0426.html) counts Unicode code points with an exclusive end. The renderer normalizes quote line endings before counting, without Unicode normalization. Unit tests check combining marks, emoji sequences, XML escaping and newline normalization. No encrypted-reply behavior is implemented or implied.

Cancellation or connection replacement during a write fails that call; its delivery outcome can still be uncertain. Reusing the durable ID does not by itself guarantee that the server or peer deduplicates retries.

`events` is a single-consumer stream with 256 buffered entries. An overflow disconnects the transport instead of continuing after silent event loss. It is not durable; the application must add durable ingestion before reliable messaging claims. Recreate the client if the event stream finishes after overflow.

`XMPPClient(labCertificateAuthority: derData)` is an explicit local-test initializer: it restricts that connection's trust anchors to the supplied DER CA while retaining account-domain hostname, certificate validity and SSL usage validation. Default construction uses system trust. Never introduce an accept-all certificate callback.

## Verification

Run `swift test --package-path Packages/XMPPProtocol` from the repository root. The tests cover byte-fragmented Unicode, stream namespace inheritance, quoted delimiters, multiple stanzas, CDATA, malformed XML, undeclared namespaces, forbidden DTD/entities, stanza/depth limits, escaping, stable identity rendering/parsing, malformed output rejection and disconnected-state behavior. These are not interoperability or security certification.

Run `python3 Packages/XMPPProtocol/Scripts/smoke.py` with the local server running for disposable-account integration checks. It checks exact Unicode/XML-special body and stanza/origin ID round-trip, reconnecting the same client/account and resending with the same ID, incorrect-password rejection, untrusted-certificate rejection and incorrect-domain rejection, then deletes the account. The additional known-ID reply case sends an original, then a reply referencing it, and checks the delivered quoted fallback plus answer exactly; it does not verify incoming structured reply metadata. Nine checks, including durable SM/MAM recovery and both OMEMO profiles’ PEP and synthetic ciphertext round trips plus sent/received carbons across three live resources, passed against the pinned local Prosody image on 2026-09-14. No macOS keychain trust was changed.

The `haus-lab` executable accepts credentials through environment variables (never command-line arguments or logs): `HAUS_LAB_DOMAIN`, `HAUS_LAB_USERNAME`, `HAUS_LAB_PASSWORD`; optional `HAUS_LAB_HOST`, `HAUS_LAB_PORT` (5223), `HAUS_LAB_CA_DER`, `HAUS_LAB_TO`, `HAUS_LAB_BODY`. It prints state, message IDs and body byte counts, not bodies/passwords. Run only with disposable lab accounts. See the repository's local infrastructure runbook.

## Next work

Separate negotiation and stanza processing into independently testable state machines; define durable ingress/egress before SM acknowledgements; add proper JID preparation and modern authentication using vetted primitives. Carbons cover live copies; bounded MAM and durable SM now provide recovery primitives as described below. Plaintext laboratory APIs are separate and must never be used as an encryption fallback.

## OMEMO wire contract

`XMPPOMEMOProfile` supports the deployed legacy `eu.siacs.conversations.axolotl` profile and modern `urn:xmpp:omemo:2`. The typed bundle/envelope/key models are `Codable` for durable ciphertext storage. `encryptedMessageXML(to:envelope:id:)` is a pure bounded encoder. No user body, quote, or reply metadata appears outside the ciphertext.

`fetchOMEMODevices(for:profile:)` returns an empty list only for an exact `item-not-found` stanza error. Authentication failures, forbidden nodes, malformed content and timeouts propagate. Fetches validate response origin, item/node association, namespaces, duplicate devices/prekeys, key lengths, base64 and limits. Publication uses open access and modern multi-item bundle nodes; an existing node configuration conflict is reconfigured and retried once. Callers must merge and recheck their own device list, validate bundle signatures, and apply fingerprint-scoped trust.

IQ requests have random IDs, exact addressed-peer response matching, local destination validation, a 64-request bound, 15-second timeout, and cancellation/disconnect cleanup. A cancelled pending request cannot be written on a later connection. XML parser limits remain 1 MiB/64 element levels. Additional limits are 512 listed devices, 1,024 recipient keys, 1,000 bundle prekeys, 16 KiB per encrypted ratchet key and 512 KiB payload (also subject to the total XML bound). These are implementation resource limits, not claims about universal XMPP maxima.

`setCarbonsEnabled()` must be called for every new connection after checking server support. Forwarded messages retain `.receivedCarbon` or `.sentCarbon` provenance. The outer sender must exactly equal the account's bare JID, its destination must match the bound resource, and the inner addresses must match the claimed direction. Foreign, nested, ambiguous and wrong-namespace wrappers are discarded as a whole. Recognized OMEMO/EME content suppresses plaintext interpretation even when encryption parsing fails.

Protocol sources checked **2026-09-14**: [XEP-0384 0.9.1](https://xmpp.org/extensions/xep-0384.html), [legacy XEP-0384 0.3.0](https://xmpp.org/extensions/attic/xep-0384-0.3.0.html), [XEP-0280 1.0.1](https://xmpp.org/extensions/xep-0280.html). The live wire smoke deliberately uses synthetic keys and payloads: it proves PEP and ciphertext transport, not cryptographic interoperability. Independent-peer crypto validation belongs to the OMEMO package's acceptance suite.

## Durable stream management and archive recovery

`configureStreamManagement(persistence:)` must run before connecting. The persistence adapter loads/saves an account-scoped `XMPPStreamManagementSnapshot` with revision CAS, exact outgoing XML, absolute UInt64 counters, the previous bound resource and server resume identifier. Every counted outgoing stanza is saved before its socket write. Acknowledgement deltas use UInt32 rollover and cannot exceed the outstanding journal. Server acceptance and removal of acknowledged entries must commit together; neither implies recipient delivery. Journal bounds are 2,000 stanzas and 4 MiB.

Incoming messages emit a following `.streamManagementBarrier(token)`. The consumer must durably process or retain the preceding event before calling `acknowledgeInbound`. Internal IQ/presence processing cannot advance the advertised handled count across a pending message. Persistence failures never advance the advertised counter. `r` replies promptly with the last **persisted contiguous** count. Connection-generation checks fence both persistence suspensions and actual socket writes.

A fresh connection authenticates before attempting XEP-0198 resumption, restores the previous resource, commits the server's accepted prefix and replays remaining **exact saved XML**. Encrypted applications must override `permitsResumption` to validate current fingerprint-scoped trust; the callback runs before attempting resume and again before replay. The default is only suitable for protocol fixtures or applications without encrypted trust policy. Failed/expired/unauthorized resumption does not replay on the newly bound stream: ciphertext stays uncertain in the separate application outbox. `<enable/>` sends no `max`. The server's advertised timeout (capped at a week) is re-stamped from every journal commit, so it runs from the last contact, and a resume is attempted for at least 72 h after it: servers keep push-enabled sessions far longer than they advertise, and a refused resume falls through to a bind on the same connection. `configureResource(_:)` sets the resource every fresh bind requests; a refused bind is retried once with a server-assigned one. `disconnectAndWait` does one ping round trip, persists h and writes a final `<a/>` within 500 ms before closing. `setAvailability(.away(since:))` makes new and resumed sessions announce XEP-0319 idle and CSI inactive.

`fetchArchivePage(_:limit:room:)` requests at most 200 own-account MAM results after or before a cursor (`XMPPArchiveBound`; `.before(nil)` is the newest page), correlates the random query ID, validates the exact archive authority, forwarding shape, timestamp, actor addresses and final RSM cursor. Only one page may be active. Foreign/unsolicited wrappers are never treated as ordinary plaintext. Results retain archive UID and server timestamp separately from sender-controlled message IDs. Prosody's absent redundant local `to` attribute is filled only after validating the own-archive wrapper. Redacted archive entries retain their UID/timestamp without inventing message content. Nested carbon/archive wrappers and unrelated inner actors are rejected.

The page returns its inbound `handledTokens`; persist every result and the archive cursor before acknowledging them. A partially received page that fails, times out or is cancelled disconnects to avoid an unrecoverable handled-counter gap. The unchanged durable archive cursor permits refetch. Returned `.sentCarbon` / `.receivedCarbon` message provenance expresses authenticated own-account direction; the enclosing `XMPPArchiveMessage` separately identifies archival origin. Ciphertext replay/authentication and cross-source deduplication remain the OMEMO/application layer's responsibility.

Verified 2026-09-14 against the pinned local Prosody 13 image: durable server acknowledgement, same-resource resumption and multi-page archive catch-up, alongside the prior eight TLS/PEP/carbon/reply checks. Tests also exercise impossible/rolled-over acknowledgements, failed persistence, pending inbound holes, forged MAM actors, duplicate archive IDs and inconsistent cursors. Fixture persistence is intentionally in memory; app persistence/restart tests belong to MessageStore/MessagingCore.

Primary protocol references checked 2026-09-14: [XEP-0198 1.6.3](https://xmpp.org/extensions/xep-0198.html) and [XEP-0313](https://xmpp.org/extensions/xep-0313.html). This does not remove the remaining DNS SRV, STARTTLS, SCRAM/SASL2, full JID preparation, group-message or physical-device lifecycle acceptance work.

## Push registration and client state

`XMPPPushConfiguration(serviceJID:node:publishOptions:)` validates a gateway's opaque registration credentials, including when decoding saved JSON. It accepts a bare gateway JID with an ASCII DNS/IDNA domain and an optional ASCII letter/digit/dot/dash/underscore local part, limits nodes to 1 KiB and publish options to 16 fields / 8 KiB, and reserves the fixed `FORM_TYPE`. Descriptions redact credentials. Encoding escapes all attribute/text values and never adds message contents or APNs tokens.

`supportsPushNotifications()` discovers support at the bound account's bare JID. `enablePush(_:)` and `disablePush(serviceJID:node:)` await the correlated account-server IQ outcome; cancellation, spoofed replies and errors retain the existing IQ fencing. Disable always requires a specific node so one installation cannot accidentally revoke other devices. Registration is not proof that APNs delivered anything. Gateway provisioning, token rotation, permission state, server-side content minimization and durable registration intent belong to the application/gateway.

`supportsClientStateIndication` reflects authenticated stream feature advertisement. `setClientActive(_:)` sends an ordered `urn:xmpp:csi:0` nonza, not presence, and does not increment SM stanza counters. New streams start active. With `setAvailability` the client itself sends CSI `<inactive/>` (away) or, on a resumed stream, `<active/>` (in front) together with presence. CSI is a hint and cannot guarantee that a server suppresses traffic or sends push notifications.

Primary sources checked 2026-09-14: [XEP-0357 0.4.1](https://xmpp.org/extensions/xep-0357.html), currently Deferred, defines `urn:xmpp:push:0`, account-level enable/disable and the `http://jabber.org/protocol/pubsub#publish-options` form; [XEP-0352 1.0.0](https://xmpp.org/extensions/xep-0352.html), Stable, defines CSI feature negotiation, processing order and resumption behavior. Validation of these widely implemented push primitives must still include real server/gateway/APNs interoperability; specification status alone supplies no delivery guarantee.

The local generated-account smoke suite now has ten passing checks, including push registration/disable and CSI with unchanged SM stanza counts. Its synthetic gateway node has no APNs connection; these checks prove only account-server protocol handling.
