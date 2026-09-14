# XMPPProtocol — first transport laboratory

Owned Swift code, Foundation XMLParser, Network.framework and Security.framework; no external package dependencies. This is a deliberately limited direct-TLS client for proving a real native connection. **It is not an encrypted messenger or a production-ready XMPP stack.**

Implemented: account-domain certificate validation (separate from transport host), TLS 1.2 minimum, SASL PLAIN inside validated TLS, XML stream restart, resource binding, initial presence, ordinary direct chat text with caller-supplied stanza/origin IDs, XEP-0199 ping responses, bounded stanza parsing and event buffering. `connect` returns only after authentication and resource binding. A 20-second deadline bounds TLS and XMPP negotiation; cancellation/disconnect invalidates the session generation.

Not implemented: DNS SRV/discovery, STARTTLS, SCRAM/SASL2, JID preparation, OMEMO, persistence, delivery acknowledgements, stream management/resumption, MAM/history, carbons, roster, rooms, reactions or media. A completed send means Network.framework accepted the bytes, **not** that the server stored or the recipient received the message. Incoming IDs are unverified server/peer fields, not globally unique database keys.

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

Cancellation or connection replacement during a write fails that call; its delivery outcome can still be uncertain. Reusing the durable ID does not by itself guarantee that the server or peer deduplicates retries.

`events` is a single-consumer stream with 256 buffered entries. An overflow disconnects the transport instead of continuing after silent event loss. It is not durable; the application must add durable ingestion before reliable messaging claims. Recreate the client if the event stream finishes after overflow.

`XMPPClient(labCertificateAuthority: derData)` is an explicit local-test initializer: it restricts that connection's trust anchors to the supplied DER CA while retaining account-domain hostname, certificate validity and SSL usage validation. Default construction uses system trust. Never introduce an accept-all certificate callback.

## Verification

Run `swift test --package-path Packages/XMPPProtocol` from the repository root. The tests cover byte-fragmented Unicode, stream namespace inheritance, quoted delimiters, multiple stanzas, CDATA, malformed XML, undeclared namespaces, forbidden DTD/entities, stanza/depth limits, escaping, stable identity rendering/parsing, malformed output rejection and disconnected-state behavior. These are not interoperability or security certification.

Run `python3 Packages/XMPPProtocol/Scripts/smoke.py` with the local server running for disposable-account integration checks. It checks exact Unicode/XML-special body and stanza/origin ID round-trip, reconnecting the same client/account and resending with the same ID, incorrect-password rejection, untrusted-certificate rejection and incorrect-domain rejection, then deletes the account. These five checks passed against the pinned local Prosody image on 2026-09-14. No macOS keychain trust was changed.

The `xmpp-lab` executable accepts credentials through environment variables (never command-line arguments or logs): `XMPP_LAB_DOMAIN`, `XMPP_LAB_USERNAME`, `XMPP_LAB_PASSWORD`; optional `XMPP_LAB_HOST`, `XMPP_LAB_PORT` (5223), `XMPP_LAB_CA_DER`, `XMPP_LAB_TO`, `XMPP_LAB_BODY`. It prints state, message IDs and body byte counts, not bodies/passwords. Run only with disposable lab accounts. See the repository's local infrastructure runbook.

## Next work

Separate negotiation and stanza processing into independently testable state machines; define durable ingress/egress before SM acknowledgements; add proper JID preparation and authenticated capability discovery; implement a modern authentication mechanism using vetted primitives. Add OMEMO explicitly before enabling everyday conversations. The application must visibly identify current laboratory plaintext and must never silently use it as an encryption fallback.
