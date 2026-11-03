# Encrypted private groups

OMEMO 2 messages and reactions in a private, nonanonymous MUC, encrypted for every member including offline ones. Exact ciphertext, recipient fingerprints, membership and ratchet advancement are stored together. Changed membership, a missing device, an undecided or rejected member key (a rejected device of the user's own account excepted, as in 1:1 chats), or an unreadable member list blocks the whole send. There is no partial-recipient and no plaintext fallback.

## Specification basis

- [XEP-0384](https://xmpp.org/extensions/xep-0384.html) 0.9.1 §5.5.1 and §5.8: `urn:xmpp:omemo:2`; recipients are the union of members, admins and owners; keys are grouped by real bare JID; the room must be nonanonymous; the SCE recipient affix names the room.
- [XEP-0045](https://xmpp.org/extensions/xep-0045.html) §9.5, §10.5, §10.8: affiliation lists in `http://jabber.org/protocol/muc#admin`, real occupant JIDs in `http://jabber.org/protocol/muc#user`. A nickname is never a cryptographic identity.
- [XEP-0420](https://xmpp.org/extensions/xep-0420.html) `urn:xmpp:sce:1`: room messages must carry both sender and recipient affixes, stricter than XEP-0384's SHOULD for the sender.
- [XEP-0313](https://xmpp.org/extensions/xep-0313.html) `urn:xmpp:mam:2`: results are accepted only inside the active query from the exact archive owner; room and account archives have separate cursors.
- [XEP-0359](https://xmpp.org/extensions/xep-0359.html) `urn:xmpp:sid:0` and [XEP-0444](https://xmpp.org/extensions/xep-0444.html): room reactions target the room-assigned stanza ID, never an encrypted origin ID.

## Interfaces

- `XMPPClient.refreshGroupRoom` reads disco and all three affiliation lists twice and requires matching results and an unchanged local presence revision. `joinGroupRoom` requests presence with history disabled; joined state comes only from authenticated self-presence (`groupPresence`, `groupRoomSnapshot`). Presence may carry several consistent `muc#user` items for one occupant (one per session); at most 100 naming the same bare JID and affiliation are accepted, mixed ones rejected. A nickname change clears joined state until self-presence confirms it.
- `OMEMOService.refreshGroupDevices` returns the live room and every member's OMEMO 2 devices without approving any fingerprint; `cachedGroupDevices` serves offline review, including pending authors who have left; `knownGroupRooms` reads stored rooms and membership. Group discovery never changes a direct chat's profile. Discovery ends with a membership reread, but self-presence can arrive after it: read `groupRoomSnapshot` again before showing joined state.
- Send: queue a normal message with `chatID` set to the room, call `prepareGroupMessage`, then just before submission `outgoingGroupEnvelope`, and pass its `PreparedGroupMessage` (envelope and expected members) to `sendEncryptedGroupMessage`. The transport rechecks membership after taking the write gate and after journaling. Never send these through the direct-message path. Stream Management resumption refuses group ciphertext; a fresh connection revalidates membership before a retry sends the saved bytes.
- Receive: `receiveGroup`, and acknowledge only once `hasDurableGroupDisposition` is true. Live authors are identified by the authenticated presence mapping and must be current members; archived authors by the archived real-JID item, and may have left, but their key still needs approval. Session-confirmation messages go to the author's real JID.
- Archives: `fetchArchivePage(_:limit:room:)` returns `encryptedGroupMessage` items; omit `room` for the account archive. Every message or retained ciphertext commits before its cursor. Unverifiable inner content yields an explicit rejection recorded before the cursor moves (at most 1,000 metadata-only rejections per account); no author claim or body is shown.
- Reactions: `queueReactions` dispatches rooms to the group path; `prepareGroupReaction` and the group drain apply the same membership and fingerprint checks.

## Room references

The room must advertise `urn:xmpp:sid:0`. Exactly one room-assigned `<stanza-id>` is accepted; a foreign `by`, outer message ID, encrypted origin ID or MAM cursor is never that reference. The reference commits atomically with authentication, ratchets and replay identity. An exact own-ciphertext echo binds the outgoing message to its assignment; a later archive copy may fill a missing reference but never change one. These references are authenticated by the room service, not end to end, and are stored apart from direct-chat origin IDs. A room ID shared by two messages suppresses association and reaction projection. Each real author's full reaction set replaces only their own earlier set; empty sets withdraw, and reactions may arrive before their target without creating a bubble.

## Boundaries

- OMEMO 2 only; legacy OMEMO has no SCE room binding.
- Existing members-only, nonanonymous rooms; at most 100 members and 1,024 recipient devices.
- The server must allow complete affiliation-list retrieval. Two consistent reads narrow but cannot close the race with a membership change, and a change after the socket write cannot revoke sent ciphertext.
- Retractions and corrections are not sent in rooms (`unsupportedMessageUpdate`).

## Testing

`swift test --package-path Packages/XMPPProtocol --filter GroupChatTests` covers room validation, presence, nickname spoofing, conflicting real JIDs, stanza-ID authority and archive author binding. `swift test --package-path Packages/OMEMO --filter GroupServiceTests` covers room-to-DM substitution, multi-recipient sealing, trust retry, former-member history, replay, offline devices, rejected keys, immutable ciphertext after membership changes and reactions. `swift test --package-path Packages/MessageStore --filter GroupReferenceTests` covers reference storage.
