# UI tests

`HausXMPPUITests` drives the app through XCUITest. Most suites launch it with `-demo` on sample data from an isolated store and need no network. The lab suites (listed under "Lab suites" below) sign in to a test XMPP server and skip unless its environment is exported.

## What runs when

The scheme `HausXMPP` has two test plans in `TestPlans/`:

- **`UISmoke`**: the panel swap, long-chat and reply-swipe tests, about two minutes. These check the software keyboard and gesture arbitration, which break most easily.
- **`UIFull`** (the scheme's default): every UI test. Each routine test launches the app once; the lab and device tests skip in a fraction of a second unless their environment is exported.

Run `UISmoke`, plus `-only-testing` for the suites of the screens you touched. Run `UIFull` before opening a pull request that changes UI.

| Suite | One launch covers |
|---|---|
| `ReplyUITests` | Reply swipes on a photo, the gutter and a bubble; small drags, cancel, the sent quote, search and the draft, the day header and leading edge going back |
| `ConversationUITests` | The long chat: no empty notice on open, the keyboard keeping the history anchor, a growing draft, one older page, search past the loaded pages |
| `AttachmentPanelUITests` | The panel swapping with the keyboard at the same height; the rail, tray, drag, rotation, leaving, a second chat's panel and the system picker |
| `MessageActionsUITests` | Compose and send controls, edit and unsend, the bubble-only overlay, star, the starred filter, text selection, an unreadable placeholder |
| `ChatListSwipeUITests` | The typing row, Pin and Mute swipes, the mute dialog and the details row |
| `AppearanceUITests` | Accent and scheme changes repainting the open Settings sheet |

Each test runs in named steps (`XCTContext.runActivity`), and every class stops at its first failure, so a red result names the step that broke.

## Running

Use one simulator that nothing else is driving, and keep derived data and result bundles inside the checkout (`build/` is gitignored):

```bash
xcodebuild test -project HausXMPP.xcodeproj -scheme HausXMPP -testPlan UISmoke \
  -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath build/DerivedData \
  -resultBundlePath build/TestResults/smoke.xcresult -collect-test-diagnostics never

# the suites for the screens you touched
xcodebuild test ... -only-testing:HausXMPPUITests/MessageActionsUITests -only-testing:HausXMPPUITests/ChatListSwipeUITests
```

`-collect-test-diagnostics never` stops a failure from running `simctl diagnose` for up to ten minutes. Delete result bundles once you have read them.

Rebuild with the scheme you are about to test. If `HausXMPPLifecycle` shares a derived data folder with a later `HausXMPP` build, running it without rebuilding fails about a dozen unrelated tests that compare errors.

The attachment suites need an iOS 26.5 simulator with the stock photos.

### A keyboard that never shows

A simulator that has seen a hardware keyboard minimises the software keyboard: it exists, but its frame sits below the screen, and the composer stays at rest. Every keyboard test then fails. `showKeyboard(tapping:)` (in `UITestSupport.swift`) fails at once in that case and says so. The cause seen so far is `AutomaticMinimizationEnabled` in `com.apple.keyboard.preferences`, which a cloned simulator can have on. Turn it off:

```bash
xcrun simctl spawn <udid> defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO
```

A typical symptom is a height assertion such as `467.0 is not equal to 826.0`.

### Screenshots

Review screenshots (`capture(_:_:)`, kept in the result bundle) are taken only when the runner has `HAUS_UI_CAPTURES=1`. Export `TEST_RUNNER_HAUS_UI_CAPTURES=1` before running `xcodebuild`. Routine runs skip them and the settle waits that go with them.

### Parallel clones

`-parallel-testing-enabled YES -parallel-testing-worker-count 3` gives each worker a fresh clone of the simulator and splits the suite by class. Each clone boots every simulator daemon, so use it only while no other simulators are booted; with several others running, clones have stalled.

## What belongs where

A UI test costs a launch (about 4 s) and one to four seconds per gesture. Write one only for what XCUITest alone can check: the software keyboard, gesture arbitration with the system back swipe, context menus, the out-of-process photo picker, permission prompts, rotation, and SwiftUI screens a hosted test cannot reach. Add new checks as named steps to the test that already opens that screen rather than as a new launch.

Everything else goes in `HausXMPPLifecycleTests` (`AppLifecycleTests/`) or a package:

- Conversation decisions shared with the Mac timeline (`App/Conversation`): which actions a message offers (`MessageActionMenuTests`), how stored messages become rows (`ConversationPresenterTests`) and where the list scrolls (`TimelineScrollPolicyTests`). Test these types directly, without a window. The `HausXMPPMac` target compiles the folder for macOS, so a UIKit dependency creeping in breaks the Mac build.
- Timeline cells: labels, sides, widths, the typing item, placeholders, edited and unsent bubbles, and that the cell wires up the shared actions. Drive the real controller in a `UIWindow`, as `TimelinePositionTests` does.
- Timeline positions: that the controller carries out the scroll policy: anchoring, loading earlier pages, following an own send (`TimelinePositionTests`).
- Composer decisions such as which item carries a reply, attachment dispatch order, mute durations.
- Persistence: pins, stars, mutes, replies and revisions are written to the store and read back before they appear on screen, and MessageStore's tests own that. Don't relaunch the app to prove it.

## Lab suites

`EncryptionUITests`, `OutboxUITests`, `ReceiptUITests`, `ReactionUITests`, `RevisionUITests`, `GroupUITests`, `AttachmentSendLabUITests`, `LastSeenLabUITests` and `NotificationActionLabUITests` sign in to a test server. They share `LabFixture` (skip unless exported, launch on an isolated store) and the steps in `LabUITestSupport.swift`: `connectToLab`, `startChat(with:)`, `selectModernOMEMO` and `acceptPendingDevices`.

They need:

- An XMPP server reachable as `localhost` with direct TLS on port 5223, a certificate from a CA of your own, and two disposable accounts. Prosody with MAM, carbons, stream management, PEP, last activity, MUC on `rooms.localhost` and HTTP file upload covers every suite. Use a fresh pair of accounts per suite, because an account collects stale OMEMO devices across runs.
- An OMEMO peer client signed in as the second account. It must accept the app's devices and, for most suites, echo each decrypted message back encrypted. **This peer is not included in the repository.** Encryption, Outbox, Receipt and Last Seen expect an echo; AttachmentSend expects no echo (an echoed photo pushes the caption off screen); Reaction and Revision expect the peer to use the modern (`urn:xmpp:omemo:2`) profile; the notification suite expects the peer to send typing notifications as well; Group expects a peer in a members-only, non-anonymous room.

Export the variables with a `TEST_RUNNER_` prefix so that Xcode passes them to the test runner. A variable set only as a prefix on the `xcodebuild` command line does not reach it.

| Variable | Meaning |
|---|---|
| `HAUS_LAB_USERNAME`, `HAUS_LAB_PASSWORD` | The app's account (a bare username on `localhost`) |
| `HAUS_LAB_CA_DER` | Base64 DER of the server's CA certificate. The app trusts it for this connection only |
| `XMPP_OMEMO_PEER` | The peer's bare JID |
| `XMPP_GROUP_ROOM` | `GroupUITests`: the room's bare JID |
| `XMPP_PEER_EXITS_AFTER` | `LastSeenLabUITests`, optional: seconds after which the peer signs off |
| `XMPP_NOTIFICATION_ACTION_LAB` | `NotificationActionLabUITests`: `1` |
| `XMPP_ACTION_TARGET`, `XMPP_ACTION_EXPECT` | Its Mark as Read step: the text of two one-shot peer messages that you send from the host, the first while the app shows the chat list, the second after it went to the background |
| `HAUS_LAB_PORT` | Optional: sign in through a local proxy on this port instead of 5223 |
| `HAUS_LAB_HOST` | Optional: the server's private LAN address, for runs on a device |

`AttachmentSendLabUITests` only catches a dropped upload request over a slow link: on loopback the upload slot round trips are too short to show the bug. Put a proxy that adds about 100 ms each way in front of the server and set `HAUS_LAB_PORT`. `AttachmentDispatchTests.testFilesQueuedDuringAPassGetTheNextPass` in the lifecycle suite catches the same bug without a server.

Two more suites need setups that are not described here and skip otherwise:

- `PushOnboardingLabUITests` (`HAUS_PUSH_LAB=1`, `XMPP_PUSH_SERVICE`): a Prosody with `mod_cloud_notify` and a stand-in push gateway component.
- `PushUITests` (`XMPP_PUSH_DEVICE_TEST=1`): a physical iPhone, real APNs and a staging server set through `HAUS_STAGING_DOMAIN` (see `Config/Local.xcconfig.example`).

Run lab suites on a simulator you don't otherwise use. `NotificationActionLabUITests` and `PushOnboardingLabUITests` use the app's primary store on purpose.

## Where the time goes

Every gesture waits for the app to go idle. A tap costs one to two seconds. A fling costs three to four, because XCTest waits for the list to stop coasting. To see a run's per-step timeline:

```bash
xcrun xcresulttool get test-results activities --path <bundle>.xcresult --test-id 'ConversationUITests/testKeyboardKeepsTheHistoryAnchorThenPagesAndSearches()'
```

Keep tests fast:

- Don't wait out a fixed timeout for something that may not appear, such as a permission prompt that only shows once per install. Wait for the first of the possible outcomes instead: `allowPhotoAccessIfAsked` returns as soon as the prompt or the rail's first photo shows, and `waitForBackground` accepts either background state.
- Read many frames from one `XCUIElement.snapshot()`. Each `frame` or `value` read on a query element is a separate round trip.
- Scroll a long way with a hard fling (`swipeDown(velocity: 4000)`) rather than many `.fast` ones.
