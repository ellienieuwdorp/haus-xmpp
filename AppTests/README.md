# UI tests

`HausXMPPUITests` drives the app through XCUITest. Most suites launch it with `-demo` on sample data from an isolated store and need no network. Suites named `…LabUITests`, and the others that sign in, skip unless the lab environment (`HAUS_LAB_*`, the echo peer) is exported; see `infra/local/README.md`.

## What runs when

The scheme `HausXMPP` has two test plans in `TestPlans/`:

- **`UISmoke`**: the panel swap, long-chat and reply-swipe keepers, about two minutes. These check the software keyboard and gesture arbitration, which break most easily.
- **`UIFull`** (the scheme's default): every UI test. Each routine test launches the app once; the lab and device tests skip in a fraction of a second unless their environment is exported.

Run `UISmoke`, plus `-only-testing` for the suites of the screens you touched. Run `UIFull` once per PR.

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

`scripts/ui-tests.sh` runs a test plan or single classes and tests from an existing build. It takes one lock (`/usr/bin/lockf` on `ui-tests.lock` in the shared git directory) for every checkout, so a second run waits for the first instead of slowing both down. It prints who holds the slot while it waits.

```bash
export HAUS_UI_SIMULATOR=<udid>                         # a simulator no other session drives
scripts/ui-tests.sh --build UISmoke                     # build-for-testing outside the lock, then the plan
scripts/ui-tests.sh MessageActionsUITests ChatListSwipeUITests   # the suites for the screens you touched
scripts/ui-tests.sh ReplyUITests/testReplySwipesKeepTheKeyboardAndLeaveBackToTheSystem
scripts/ui-tests.sh --captures UIFull                   # with review screenshots
```

Derived data goes to `build/DerivedData` and result bundles to `build/TestResults`, both inside the checkout and ignored. Arguments after `--` go to `xcodebuild`, for example `-- -quiet`. The script passes `-collect-test-diagnostics never`: otherwise a failure runs `simctl diagnose` for up to 600 s while the slot is held. Delete result bundles once you have read them.

Rebuild with the scheme you are about to test. If `HausXMPPLifecycle` shares a derived data folder with a later `HausXMPP` build, running it without rebuilding fails about a dozen unrelated tests that compare errors.

The attachment suites need an iOS 26.5 simulator with the stock photos.

### A keyboard that never shows

A simulator that has seen a hardware keyboard minimises the software keyboard: it exists, but its frame sits below the screen, and the composer stays at rest. Every keyboard test then fails. `showKeyboard(tapping:)` (in `UITestSupport.swift`) fails at once in that case and says so; the script warns before the run. On 2026-10-08 a cloned simulator had `AutomaticMinimizationEnabled` on in `com.apple.keyboard.preferences`. Turning it off fixed the panel test, and turning it back on broke it again:

```bash
xcrun simctl spawn <udid> defaults write com.apple.keyboard.preferences AutomaticMinimizationEnabled -bool NO
```

This is a likely cause of the earlier "fails on a freshly cloned simulator" reports (`467.0 is not equal to 826.0`).

### Screenshots

Review screenshots (`capture(_:_:)`, kept in the result bundle) are taken only when the runner has `HAUS_UI_CAPTURES=1`. Pass `--captures` to the script, or export `TEST_RUNNER_HAUS_UI_CAPTURES=1` for `xcodebuild`. Routine runs skip them and the settle waits that go with them.

### Parallel clones

`-parallel-testing-enabled YES -parallel-testing-worker-count 3` gives each worker a fresh clone of the simulator and splits the suite by class. Each clone boots every simulator daemon, so only use it while no other simulators are booted. On 2026-09-29, with four other simulators running, the load average passed 800 and two clones stalled. There is no measurement yet from an idle machine.

## What belongs where

A UI test costs a launch (about 4 s) and one to four seconds per gesture. Write one only for what XCUITest alone can check: the software keyboard, gesture arbitration with the system back swipe, context menus, the out-of-process photo picker, permission prompts, rotation, and SwiftUI screens a hosted test cannot reach. Add new checks as named steps to the keeper that already opens that screen rather than as a new launch.

Everything else goes in `HausXMPPLifecycleTests` (`AppLifecycleTests/`) or a package:

- Timeline cells: labels, sides, actions, widths, the typing item, placeholders, edited and unsent bubbles. Drive the real controller in a `UIWindow`, as `TimelinePositionTests` does.
- Timeline positions: anchoring, loading earlier pages, following an own send (`TimelinePositionTests`).
- Composer decisions such as which item carries a reply, attachment dispatch order, mute durations.
- Persistence: pins, stars, mutes, replies and revisions are written to the store and read back before they appear on screen, and MessageStore's tests own that. Don't relaunch the app to prove it.

## Lab suites

The lab suites share `LabFixture` (skip unless exported, launch on an isolated store) and the steps in `LabUITestSupport.swift`: `connectToLab`, `startChat(with:)`, `selectModernOMEMO` and `acceptPendingDevices`. Give each suite a fresh fixture, because an account collects stale OMEMO devices across runs:

```bash
work/push-gateway-venv/bin/python infra/local/create_group_fixture.py work/lab/<suite> --runner-environment work/lab/<suite>/runner.json
```

Start the peer that suite needs from `Packages/OMEMO/Scripts/Interop` with `--credentials work/lab/<suite>/peer.json --state work/lab/<suite>/peer-state.json --ca work/lab/<suite>/ca.crt`, and wait for its ready line. Which peer:

- `peer.py --echo` for Encryption, Outbox, Receipt and Last Seen.
- `peer.py` without `--echo` for AttachmentSend: echoed photos push the caption off screen, where its state cannot be read.
- `peer.py --echo --profile modern` for Reaction and the peer half of Revision.
- `peer.py --echo --typing` for the notification lab, also exporting `TEST_RUNNER_XMPP_NOTIFICATION_ACTION_LAB=1`.
- `group_peer.py --room <room>` for Group.

Then `export` every runner key with a `TEST_RUNNER_` prefix. Add `TEST_RUNNER_HAUS_LAB_CA_DER`, the base64 DER of `ca.crt`. Run the suite with `scripts/ui-tests.sh <Suite>`, which passes the exported variables on. A variable set only as a prefix on the `xcodebuild` command did not reach the runner.

To run a lab suite over a slow link, start `infra/local/slow_link.py` in front of the lab (for example `--listen 15223 --target 5223 --delay 0.1` for a 200 ms round trip) and also export `TEST_RUNNER_HAUS_LAB_PORT=15223`. `connectToLab` then signs in through that port. `AttachmentSendLabUITests` needs it to fail on code that drops an upload request: on loopback the slot round trips are too short to show the bug. `AttachmentDispatchTests.testFilesQueuedDuringAPassGetTheNextPass` in the lifecycle suite catches that bug without the lab.

## Where the time goes

Every gesture waits for the app to go idle. A tap costs one to two seconds. A fling costs three to four, because XCTest waits for the list to stop coasting. To see a run's per-step timeline:

```bash
xcrun xcresulttool get test-results activities --path <bundle>.xcresult --test-id 'ConversationUITests/testKeyboardKeepsTheHistoryAnchorThenPagesAndSearches()'
```

Keep tests fast:

- Don't wait out a fixed timeout for something that may not appear, such as a permission prompt that only shows once per install. Wait for the first of the possible outcomes instead: `allowPhotoAccessIfAsked` returns as soon as the prompt or the rail's first photo shows, and `waitForBackground` accepts either background state.
- Read many frames from one `XCUIElement.snapshot()`. Each `frame` or `value` read on a query element is a separate round trip.
- Scroll a long way with a hard fling (`swipeDown(velocity: 4000)`) rather than many `.fast` ones.
