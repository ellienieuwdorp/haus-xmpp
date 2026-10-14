# Name and icon

The code is free software under the GPL. The name "Haus XMPP" and the app icon are not covered by that grant: section 7(e) of the GPL lets a licensor decline to grant rights under trademark law, and this project does.

The name and icon tell people that a build comes from this project. Please keep it that way:

- **Allowed without asking**: building and running the app for yourself; saying your project is "based on Haus XMPP" or "compatible with Haus XMPP"; using the name in articles, reviews and talks.
- **Not allowed without written permission**: publishing a modified or rebuilt app under the name "Haus XMPP" or a confusingly similar name, or with the Haus XMPP icon, in any app store or download site.

If you publish a fork, choose a new name, replace `App/Assets.xcassets/AppIcon.appiconset/AppIcon.png`, and change the identifiers: the bundle identifiers in `project.yml`, the app group in the four `.entitlements` files and in `Shared/SharedStorage.swift`, and the push service in `App/PushService.swift`.

Questions about the name or icon: open an issue.
