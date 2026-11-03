# Message reactions

## Wire contract

- [XEP-0444](https://xmpp.org/extensions/xep-0444.html#businessrules) 0.2.1 §3–4, `urn:xmpp:reactions:0`: each update replaces the actor's whole emoji set for one message; an empty set clears it; duplicates are ignored. In a direct chat the actor must be one of the two parties, and an older delayed update never replaces a newer one.
- OMEMO 2 chats ([XEP-0384](https://xmpp.org/extensions/xep-0384.html#usecases-sending) 0.9.1 §5.5): the reaction is encrypted inside `urn:xmpp:sce:1` content with sender and recipient affixes and random padding.
- Legacy OMEMO chats (`eu.siacs.conversations.axolotl`): the profile protects body text only, and putting reaction XML in the encrypted body would be a private format. Conversations and its forks send and expect plain XEP-0444, so reactions, receipts (XEP-0184) and retractions (XEP-0424) travel as plain stanzas the servers can read; message text never does ([XEP-0420](https://xmpp.org/extensions/xep-0420.html#motivation) 0.5.0 §5 describes this metadata exposure). The UI must not present these as encrypted, and a modern chat never sends them plain.

## Guarantees

- Outgoing OMEMO 2 messages carry their origin ID inside SCE as well as outside. A modern reaction may target only a message whose reference is authenticated and unique within the account and chat; ambiguous references select nothing, and received outer IDs never authorize a target.
- A legacy reaction names its target by the stored wire ID, outside the ciphertext. An incoming plain reaction has a server-authenticated sender and an unauthenticated target, which must still resolve to one stored message.
- Reactions have their own durable intentions, ciphertext and events and never create chat bubbles. Ratchets and ciphertext commit together; the drain claims only prepared IDs, replays only the exact saved bytes after rechecking trust, and treats a written stanza as uncertain until the server accepts it.
- Each actor's latest set is projected independently. Reactions to a missing target wait for it. Ciphertext replay or a repeated event ID cannot rewrite earlier events.
- Archive delay times order history (server metadata, not cryptographic ordering). Future times are capped at local receipt. An authenticated SCE time must lie within five minutes of the archive or live time; outgoing reactions omit it so a delayed resend of the exact ciphertext stays valid.
- At most 12 emoji per set, 64 UTF-8 bytes and one extended grapheme cluster each.

## Interoperability notes

A foreign OMEMO 2 client may react to our authenticated IDs, but if its own messages omit an authenticated inner origin ID they stay readable and cannot receive our private reactions. QXmpp at `8476ee8e9edae40e909d01d85f25c7239a6b30d4` serializes reactions in `SceSensitive` and the origin ID in `ScePublic` ([QXmppMessage.cpp](https://github.com/qxmpp-project/qxmpp/blob/8476ee8e9edae40e909d01d85f25c7239a6b30d4/src/base/QXmppMessage.cpp#L1847)), which is such a case.

## Testing

`swift test --package-path Packages/OMEMO` covers reaction-only content, replacement and clearing, Unicode limits, malformed and ambiguous XML, sender and recipient binding, delayed ordering, future timestamps, replay and retry, and legacy plain sending. `swift test --package-path Packages/MessageStore` covers atomic sealing, claims, acknowledgement, target collisions, actor isolation, event replay and pending targets.
