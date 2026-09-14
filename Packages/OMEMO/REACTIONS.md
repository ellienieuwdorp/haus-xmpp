# Private message reactions

Implementation/research date: 2026-09-14. This is the modern direct-message reaction path. It does not claim legacy encrypted reaction compatibility or group support.

## Wire contract

XEP-0444 uses `urn:xmpp:reactions:0`. Each update replaces the authenticated actor's whole emoji set for one message; an empty set clears it. Duplicate emoji are ignored. Direct-chat actors must be one of the two parties, and delayed older updates must not replace newer ones. References use an origin ID where present. [XEP-0444 §3–4, version 0.2.1](https://xmpp.org/extensions/xep-0444.html#businessrules).

Modern OMEMO uses `urn:xmpp:omemo:2` with encrypted `urn:xmpp:sce:1` content. Reaction XML belongs inside that encrypted content. We always include sender/recipient affixes and random padding. [XEP-0384 §5.5, version 0.9.1](https://xmpp.org/extensions/xep-0384.html#usecases-sending).

Legacy `eu.siacs.conversations.axolotl` protects body text. Treating encrypted body text as executable reaction XML would introduce a private, incompatible format. Sending outer reaction XML would expose it. Both are rejected. SCE describes the metadata disclosure caused by the historical body-only format. [XEP-0420 §5, version 0.5.0](https://xmpp.org/extensions/xep-0420.html#motivation).

## Existing implementation evidence

Kaidan's 0.9 release introduced OMEMO 2, encrypted metadata and reactions. [Kaidan release announcement](https://www.kaidan.im/2023/05/05/kaidan-0.9.0/).

QXmpp revision `8476ee8e9edae40e909d01d85f25c7239a6b30d4` parses and serializes reaction elements in `SceSensitive`; its origin-ID handling is in `ScePublic`. This verifies an existing encrypted reaction construction, but reveals a target-authentication interoperability gap. [QXmppMessage.cpp](https://github.com/qxmpp-project/qxmpp/blob/8476ee8e9edae40e909d01d85f25c7239a6b30d4/src/base/QXmppMessage.cpp#L1847).

## Application policy and limits

- Outgoing modern texts include their origin ID inside SCE as well as the normal outer stanza. Only a unique, authenticated message reference within the account and chat is eligible for a reaction. Duplicate/ambiguous references do not select an arbitrary message. Received outer IDs alone never authorize a reaction target.
- A foreign modern client may send an encrypted reaction to one of our authenticated IDs. Its own messages may omit an authenticated inner origin ID; those messages remain readable but are not eligible for private reaction sending here. This deliberate restriction needs a shipping-client compatibility decision before broad release. It is not advertised as full Kaidan/QXmpp reaction interoperability.
- Reactions have dedicated durable intentions, ciphertext, and events. They never create fake chat bubbles. Updated ratchets and ciphertext commit together. The sender claims only prepared IDs, retries exact ciphertext, checks fingerprint trust before replay, and distinguishes an uncertain write from server acceptance.
- Each actor's latest complete set is projected independently. Missing targets remain unprojected until their authenticated message arrives. Ciphertext replay and repeated authenticated event IDs cannot rewrite earlier events.
- Valid archive delay times determine historical ordering; these are server-provided metadata, not cryptographic total ordering. Future times are capped at local reception time so they cannot permanently freeze updates. A present authenticated SCE time must agree with the supplied archive/live time within five minutes. Outgoing reactions omit optional SCE time to preserve compatibility with delayed exact-ciphertext sends.
- The implementation accepts at most 12 emoji per set, 64 UTF-8 bytes each, and one extended grapheme cluster per emoji. The current Unicode runtime recognizes emoji presentation and explicit emoji/keycap sequences.
- Groups, reaction restrictions/gateway error rollback, and an independent shipping-client reaction exchange remain release work. No plaintext fallback is enabled to make those cases appear supported.

## Validation

`swift test --package-path Packages/OMEMO` exercises reaction-only content, replacement/clear, Unicode, malformed and ambiguous XML, sender/recipient binding, private origin IDs, delayed ordering, future timestamps, no extra bubbles, ciphertext replay/retry, and explicit legacy refusal. `MessageStore` separately tests atomic sealing, claim ownership, acknowledgment, target collisions, actor isolation, event replay and pending targets.
