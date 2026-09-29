# UI tests

`HausXMPPUITests` drives the app through XCUITest. Most suites launch it with `-demo` on sample data from an isolated store and need no network. Suites named `…LabUITests`, and the others that sign in, skip unless the lab environment (`HAUS_LAB_*`, the echo peer) is exported; see `infra/local/README.md`.

## Running

Build once, then run as often as needed without rebuilding:

```bash
xcodebuild build-for-testing -scheme HausXMPP -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath work/DerivedData-ui
xcodebuild test-without-building -scheme HausXMPP -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath work/DerivedData-ui -only-testing:HausXMPPUITests/ConversationUITests
```

Rebuild with the scheme you are about to test. If `HausXMPPLifecycle` shares a derived data folder with a later `HausXMPP` build, running it without rebuilding fails about a dozen unrelated tests that compare errors.

Use a simulator no other session drives. The attachment suites need an iOS 26.5 device with the stock photos.

`-parallel-testing-enabled YES -parallel-testing-worker-count 3` gives each worker a fresh clone of the simulator and splits the suite by class. Each clone boots every simulator daemon, so only use it while no other simulators are booted. On 2026-09-29, with four other simulators running, the load average passed 800 and two clones stalled. There is no measurement yet from an idle machine.

## Where the time goes

Every gesture waits for the app to go idle. A tap costs one to two seconds. A fling costs three to four, because XCTest waits for the list to stop coasting. To see a run's per-step timeline:

```bash
xcrun xcresulttool get test-results activities --path <bundle>.xcresult --test-id 'ConversationUITests/testKeyboardKeepsTheHistoryAnchor()'
```

Keep tests fast:

- Don't wait out a fixed timeout for something that may not appear, such as a permission prompt that only shows once per install. Wait for the first of the possible outcomes instead: `allowPhotoAccessIfAsked` returns as soon as the prompt or the rail's first photo shows, and `waitForBackground` accepts either background state.
- Read many frames from one `XCUIElement.snapshot()`. Each `frame` or `value` read on a query element is a separate round trip.
- Scroll a long way with a hard fling (`swipeDown(velocity: 4000)`) rather than many `.fast` ones.
- Don't relaunch the app just to prove that something persisted. Pins, stars, mutes, replies and revisions are written to the store and read back from it before they appear on screen, and MessageStore's tests own persistence.
- Timeline positions (anchoring, loading earlier pages, following an own send) belong in `AppLifecycleTests/TimelinePositionTests`, which drives the real controller in a window in milliseconds.
