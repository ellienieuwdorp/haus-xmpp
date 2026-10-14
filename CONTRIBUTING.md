# Contributing

Thanks for helping. Bug reports, interoperability reports from other clients and servers, and focused pull requests are all welcome.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Security problems go through [SECURITY.md](SECURITY.md), not public issues or pull requests.
- Never include real conversations, account passwords, push tokens, device logs or screenshots of real chats. Use the sample conversations ("Explore sample conversations") or throwaway test accounts.

## Licence of contributions

Haus XMPP is licensed under GPL-3.0-or-later with an additional permission for Apple distribution services (`LICENSE-ADDITIONAL-PERMISSION`). The App Store builds depend on every contributor's code carrying that permission.

By submitting a contribution you agree that it is licensed under GPL-3.0-or-later **with** the Haus XMPP Additional Permission for Apple Distribution Services, and you certify the [Developer Certificate of Origin 1.1](https://developercertificate.org/). Sign off every commit:

```sh
git commit -s
```

The sign-off line (`Signed-off-by: Your Name <email>`) must use your real name or a name you are known by. Pull requests whose commits are not signed off cannot be merged.

Do not copy code from other projects into a pull request unless you say so in the pull request and its licence is compatible. Say where it came from in a comment next to the code.

## Building and testing

See the README for build instructions. Before opening a pull request:

```sh
swift test --package-path Packages/<package you changed>
```

For app changes, build both the `HausXMPP` and the `HausXMPPMac` scheme, run the `HausXMPPLifecycle` tests, and try the change in the simulator. For UI changes, run the `UISmoke` test plan and the UI suites of the screens you touched (see `AppTests/README.md`). Tests named `…LabTests` and `…LabUITests` need a live server and skip themselves otherwise; you don't need to run them.

`project.yml` is the source of the Xcode project. If you add or move files, run `xcodegen generate` and commit the regenerated `HausXMPP.xcodeproj`. Keep your team ID and other local values in `Config/Local.xcconfig`, never in `project.yml`.

## Style

- Swift 6 with strict concurrency. SwiftUI for the app shell; UIKit or AppKit only where SwiftUI falls short.
- A message UI change is finished when it works on both iPhone and Mac.
- Don't add third-party dependencies without discussing them in an issue first. Never implement cryptographic primitives; never patch the vendored libomemo-c sources.
- Encryption must never silently fall back to plaintext.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `fix(omemo): reject a changed identity key`.
