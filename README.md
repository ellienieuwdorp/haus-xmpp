# Haus XMPP

Haus XMPP is a new native iOS XMPP client, currently an early **local development prototype**. The product identity is `Haus XMPP` under the `xmpp.haus` domain: bundle identifiers are `haus.xmpp.ios` and `haus.xmpp.ios.notifications`, and the app's own protocol namespaces live under `https://xmpp.haus/`.

The app builds and runs in the iOS simulator. It has a SwiftUI shell, UIKit conversation timeline, selectable messages, local stars/pins, swipe-to-reply with persisted quotes, native search controls and SQLite persistence. Our own Swift protocol stack connects through validated direct TLS and now exchanges legacy and modern OMEMO encrypted direct messages. Device trust and encryption live in an isolated business package; exact ciphertext and ratchet changes commit together before transport. Focused, pinned crypto dependencies are reused without maintaining a protocol/client fork.

**This is not ready for personal conversations.** Encrypted direct messaging, archive/stream recovery and modern reactions work in the lab. Private encrypted groups now pass joining, explicit device review, text/reaction exchange and reconnect recovery with an independent test peer. Decrypted notification previews and protected background persistence have passed physical iPhone checks on the isolated staging server. Full XMPP addresses can now sign in over direct TLS (port 5223) for development use; media transfer and the complete release validation matrix remain unfinished. Sample conversations use separate local fixtures.

## Build and run

Open `HausXMPP.xcodeproj`, select the `HausXMPP` scheme and an iOS 26+ simulator, then Run. No developer team is needed for the simulator. Use “Explore sample conversations” for the interface, or follow the [local lab runbook](infra/local/README.md) for a live connection.

`project.yml` is the source of project configuration; regenerate with the installed `xcodegen generate` after adding files or changing targets. The generated Xcode project and shared scheme are committed so XcodeGen is not required just to build.

```sh
swift test --package-path Packages/MessageStore
swift test --package-path Packages/XMPPProtocol
swift test --package-path Packages/MessagingCore
swift test --package-path Packages/OMEMOCrypto
swift test --package-path Packages/OMEMO
```

Run the `HausXMPP` test action in Xcode for simulator UI checks. The optional live lab UI test skips unless provided disposable credentials. See [production-readiness evidence](docs/development/production-readiness.md), [notification previews](docs/development/notification-previews.md), [encrypted groups](docs/development/group-conversations.md) and the [independent interoperability matrix](docs/development/interop-matrix.md).

## Direction

Reliable notifications, full OMEMO interoperability, core reactions, excellent search, media organization and a simple modern interface remain the product goals. We own the protocol stack, reuse focused components as appropriate, and avoid paid dependencies by default. No project license has been selected; the remote is private. The selected GPL crypto dependency has an App Store additional permission; app distribution terms remain to be resolved. See its package README for exact provenance and terms.

Read the [accepted decisions](docs/preliminary/16-accepted-direction-and-local-development.md), [research index](docs/preliminary/README.md).
