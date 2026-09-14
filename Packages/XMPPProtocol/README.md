# XMPPProtocol — transport and OMEMO wire

Owned Swift code, Foundation XMLParser, Network.framework and Security.framework; no external package dependencies. This is a deliberately limited direct-TLS client. It transports typed encrypted envelopes; cryptography and trust belong to the separate OMEMO packages. **This package alone is not an encrypted messenger or a production-ready XMPP stack.**

Implemented: account-domain certificate validation (separate from transport host), TLS 1.2 minimum, SASL PLAIN inside validated TLS, XML stream restart, resource binding, initial presence, ordinary direct chat text with caller-supplied stanza/origin IDs, XEP-0199 ping responses, bounded stanza parsing and event buffering. `connect` returns only after authentication and resource binding. A 20-second deadline bounds TLS and XMPP negotiation; cancellation/disconnect invalidates the session generation.

Also implemented: correlated IQ requests, service feature discovery, OMEMO PEP device lists/bundles, typed ciphertext send/receive, device-list events, and sent/received message carbons with strict wrapper provenance.

Not implemented: DNS SRV, STARTTLS, SCRAM/SASL2, complete JID preparation, cryptography, persistence, delivery acknowledgements, stream management/resumption, MAM/history, roster, rooms, reactions or media. A completed send means Network.framework accepted the bytes, **not** that the server stored or the recipient received the message. Incoming IDs are unverified server/peer fields, not globally unique database keys.

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

Run `python3 Packages/XMPPProtocol/Scripts/smoke.py` with the local server running for disposable-account integration checks. It checks exact Unicode/XML-special body and stanza/origin ID round-trip, reconnecting the same client/account and resending with the same ID, incorrect-password rejection, untrusted-certificate rejection and incorrect-domain rejection, then deletes the account. The additional known-ID reply case sends an original, then a reply referencing it, and checks the delivered quoted fallback plus answer exactly; it does not verify incoming structured reply metadata. Eight checks, including both OMEMO profiles’ PEP and synthetic ciphertext round trips plus sent/received carbons across three live resources, passed against the pinned local Prosody image on 2026-09-14. No macOS keychain trust was changed.

The `xmpp-lab` executable accepts credentials through environment variables (never command-line arguments or logs): `XMPP_LAB_DOMAIN`, `XMPP_LAB_USERNAME`, `XMPP_LAB_PASSWORD`; optional `XMPP_LAB_HOST`, `XMPP_LAB_PORT` (5223), `XMPP_LAB_CA_DER`, `XMPP_LAB_TO`, `XMPP_LAB_BODY`. It prints state, message IDs and body byte counts, not bodies/passwords. Run only with disposable lab accounts. See the repository's local infrastructure runbook.

## Next work

Separate negotiation and stanza processing into independently testable state machines; define durable ingress/egress before SM acknowledgements; add proper JID preparation and modern authentication using vetted primitives. Carbons cover live copies only: MAM recovery is still missing. Plaintext laboratory APIs are separate and must never be used as an encryption fallback.

## OMEMO wire contract

`XMPPOMEMOProfile` supports the deployed legacy `eu.siacs.conversations.axolotl` profile and modern `urn:xmpp:omemo:2`. The typed bundle/envelope/key models are `Codable` for durable ciphertext storage. `encryptedMessageXML(to:envelope:id:)` is a pure bounded encoder; `decodeEncryptedMessageXML(_:)` applies the transport's XML limits to one complete stanza. No user body, quote, or reply metadata appears outside the ciphertext.

`fetchOMEMODevices(for:profile:)` returns an empty list only for an exact `item-not-found` stanza error. Authentication failures, forbidden nodes, malformed content and timeouts propagate. Fetches validate response origin, item/node association, namespaces, duplicate devices/prekeys, key lengths, base64 and limits. Publication uses open access and modern multi-item bundle nodes; an existing node configuration conflict is reconfigured and retried once. Callers must merge and recheck their own device list, validate bundle signatures, and apply fingerprint-scoped trust.

IQ requests have random IDs, exact addressed-peer response matching, local destination validation, a 64-request bound, 15-second timeout, and cancellation/disconnect cleanup. A cancelled pending request cannot be written on a later connection. XML parser limits remain 1 MiB/64 element levels. Additional limits are 512 listed devices, 1,024 recipient keys, 1,000 bundle prekeys, 16 KiB per encrypted ratchet key and 512 KiB payload (also subject to the total XML bound). These are implementation resource limits, not claims about universal XMPP maxima.

`setCarbonsEnabled()` must be called for every new connection after checking server support. Forwarded messages retain `.receivedCarbon` or `.sentCarbon` provenance. The outer sender must exactly equal the account's bare JID, its destination must match the bound resource, and the inner addresses must match the claimed direction. Foreign, nested, ambiguous and wrong-namespace wrappers are discarded as a whole. Recognized OMEMO/EME content suppresses plaintext interpretation even when encryption parsing fails.

Protocol sources checked **2026-09-14**: [XEP-0384 0.9.1](https://xmpp.org/extensions/xep-0384.html), [legacy XEP-0384 0.3.0](https://xmpp.org/extensions/attic/xep-0384-0.3.0.html), [XEP-0280 1.0.1](https://xmpp.org/extensions/xep-0280.html). The live wire smoke deliberately uses synthetic keys and payloads: it proves PEP and ciphertext transport, not cryptographic interoperability. Independent-peer crypto validation belongs to the OMEMO package's acceptance suite.
