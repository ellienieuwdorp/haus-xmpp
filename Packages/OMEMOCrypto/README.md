# OMEMOCrypto

Synchronous OMEMO cryptography for Apple platforms: no UI, networking, database, logging or account service. Policy lives in `Packages/OMEMO`; this package only seals, opens and ratchets.

## Vendored dependencies

The Double Ratchet, X3DH, Curve25519/Ed25519 conversion, signatures and Signal/OMEMO protobufs come from **unmodified libomemo-c 0.5.1** at revision `1f0b37fee3ebefc46c32f882623481899a1ba568` (Dino's upstream; vendored because it ships no Swift package). `protobuf-c` 1.5.2 at `4719fdd7760624388c2c5b9d6759eb6a47490626` supplies the protobuf runtime. `VendorManifest.json` records the SHA-256 of every vendored file, and `Scripts/verify_vendor.py` fails if any file is missing or differs. Never patch vendored source; an upgrade replaces the whole inventory and repeats an independent interoperability check (for example against Python oldmemo/twomemo).

The bridge in `COMEMOBridge` supplies CommonCrypto SHA/HMAC/AES and Security randomness to libomemo-c, plus an in-memory record store. Swift uses CryptoKit for AES-GCM, HKDF and HMAC. No primitive or ratchet is implemented here.

Sources: [libomemo-c](https://github.com/dino/libomemo-c/tree/1f0b37fee3ebefc46c32f882623481899a1ba568), [its licence](https://github.com/dino/libomemo-c/blob/1f0b37fee3ebefc46c32f882623481899a1ba568/LICENSE), [protobuf-c](https://github.com/protobuf-c/protobuf-c/tree/4719fdd7760624388c2c5b9d6759eb6a47490626), [XEP-0384](https://xmpp.org/extensions/xep-0384.html) (accessed 2026-09-14).

**Licences.** libomemo-c is GPL-3.0-only with its authors' additional permission for App Store distribution under MPL-2.0; the licence section is in `NOTICE.libomemo-c` and the GPL text in `LICENSE.libomemo-c`. The app is therefore GPL-3.0 (see the repository's `LICENSE`, `LICENSE-ADDITIONAL-PERMISSION` and `THIRD_PARTY_LICENSES.md`). protobuf-c is BSD-2-Clause (`LICENSE.protobuf-c`). Keep these files beside the vendored sources.

## Profiles

- `.legacy`: `eu.siacs.conversations.axolotl`, Signal protocol 3; 33-byte serialized public keys; AES-128-GCM payload with a 12-byte IV; the ratchet carries the 16-byte key and 16-byte tag. Receive also accepts the older form (16-byte key, tag appended to the payload), chosen by key length; an authentication failure never retries the other form ([Monal MLOMEMO.m at a206db3](https://github.com/monal-im/Monal/blob/a206db31f552dd0884a6cdf7af096a5a89fec586/Monal/Classes/MLOMEMO.m#L1487) does the same).
- `.modern`: `urn:xmpp:omemo:2`, libomemo-c protocol 4; 32-byte Ed25519 identity, 32-byte Montgomery prekeys; AES-256-CBC with HMAC-SHA256 truncated to 128 bits and HKDF-SHA256 info `OMEMO Payload`; the ratchet carries a 32-byte key and 16-byte tag. The IV is derived, never sent. The caller builds and authenticates SCE.

## Public surface and contract

- `OMEMOEngine` is deliberately not `Sendable`: one ephemeral instance per account, device and profile. Load it from a snapshot inside the caller's transaction, pin accepted remote identities with `trustIdentity`, encrypt or decrypt, then persist `snapshot()` atomically with the resulting message and ciphertext. Discard the instance after any failure. Never send ciphertext before its state is durable, and never regenerate ciphertext for a retry.
- `OMEMOEngine(profile: .modern, sharingIdentityWith: legacy)` advertises one device ID in both profiles with one identity pair and separate prekeys, sessions and snapshots. Never use it to replace a published identity.
- Unknown identities are rejected. A changed identity is rejected until the caller accepts the fingerprint and calls `trustIdentity(..., resetSession: true)`. Trust and sessions are keyed by bare JID and device ID and never shared across snapshots.
- `fingerprintBytes(for:profile:)` returns the raw 32-byte Curve25519 key XEP-0384 recommends for display; trust state compares the full identity key.
- `rotateSignedPreKeyIfNeeded` rotates weekly and keeps retired signed prekeys for 30 days; persist before publishing the new bundle. `replenishPreKeys` refills consumed slots with new IDs. Consumed one-time prekeys are deleted at once (permitted by XEP-0384 §8), so a different delayed initiation reusing one fails and needs user-mediated recovery.
- **Snapshots are secret plaintext**: private keys, prekeys, pins, sessions and skipped keys. Protect them at rest, keep them out of backups and logs, and serialize every mutation. Swift `Data` copies prevent guaranteed zeroization; the C side wipes buffers before freeing.
- `AttachmentCrypto` implements [XEP-0454](https://xmpp.org/extensions/xep-0454.html): AES-256-GCM ciphertext followed by the 16-byte tag, a random 32-byte key and 12-byte IV, in memory up to 32 MiB by default. Key and IV travel only inside encrypted message content.
- `PayloadCrypto` seals and opens message payloads for both profiles.

## Testing

From the repository root:

```sh
swift test --package-path Packages/OMEMOCrypto
swift test --package-path Packages/OMEMOCrypto --sanitize=address
python3 Packages/OMEMOCrypto/Scripts/verify_vendor.py
```

The tests cover both profiles: session setup and reply, restart from snapshots, out-of-order and duplicate messages, prekey replenishment, bad bundle signatures, unknown and changed identities, sender separation, corrupted ciphertext, profile mismatch, malformed input, and signed-prekey rotation including a delayed message from a retired bundle.
