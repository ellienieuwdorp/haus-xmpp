# XMPP iOS

A new native iOS XMPP client, currently at its first **local development prototype**. `XMPP Lab` is a temporary build name, not a chosen product name.

The app builds and runs in the iOS simulator. It has a SwiftUI shell, UIKit conversation timeline, selectable messages, local stars/pins and SQLite persistence. A new Swift protocol package can connect through validated direct TLS, authenticate, bind and exchange lab messages. No protocol library fork or external package dependency is adopted.

**This is not ready for personal conversations.** OMEMO, reliable synchronization/outbox, reactions, media and production notifications are still to be implemented. The app explicitly limits network sends to the local lab. Sample conversations are local fixtures, clearly separated from lab accounts.

## Build and run

Open `XMPPiOS.xcodeproj`, select the `XMPPiOS` scheme and an iOS 26+ simulator, then Run. No developer team is needed for the simulator. Use “Explore sample conversations” for the interface, or follow the [local lab runbook](infra/local/README.md) for a live connection.

`project.yml` is the source of project configuration; regenerate with the installed `xcodegen generate` after adding files or changing targets. The generated Xcode project and shared scheme are committed so XcodeGen is not required just to build.

```sh
swift test --package-path Packages/MessageStore
swift test --package-path Packages/XMPPProtocol
```

Run the `XMPPiOS` test action in Xcode for simulator UI checks. The optional live lab UI test skips unless provided disposable credentials. See [development status and checks](docs/development/first-milestone.md).

## Direction

Reliable notifications, full OMEMO interoperability, core reactions, excellent search, media organization and a simple modern interface remain the product goals. We own the protocol stack, reuse focused components as appropriate, and avoid paid dependencies by default. No project license has been selected; the remote is private.

Read the [accepted decisions](docs/preliminary/16-accepted-direction-and-local-development.md), [research index](docs/preliminary/README.md).
