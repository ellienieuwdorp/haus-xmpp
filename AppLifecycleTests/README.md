# Encryption lifecycle diagnostics

Run the **XMPPiOSLifecycle** scheme. It hosts `XMPPiOSLifecycleTests` inside the app, uses an isolated UI storage namespace, and creates only generated synthetic account/key fixtures under `Application Support/Messaging/LifecycleTests`. There are no network calls and no real-account reads. Ordinary fixtures and their dedicated Keychain items are deleted after each test. The separate-process seed persists until its matching verification run.

The standard suite checks device-local Keychain accessibility metadata, stable key reload, encrypted OMEMO identity restoration, backup exclusion and fail-closed behavior after a wrapping key disappears. The physical-only metadata test checks the actual Data Protection class on the directory, SQLite database, WAL, SHM and transport lock file. Simulator runs explicitly skip that assertion because the simulator filesystem does not expose physical iOS Data Protection attributes.

## Actual process relaunch

Run only `XMPPiOSLifecycleTests/EncryptionLifecycleTests/testIdentityAcrossSeparateProcessLaunches` twice in separate test invocations. Supply the same fresh UUID as test-runner environment `XMPP_LIFECYCLE_RUN_ID`, with `XMPP_LIFECYCLE_PHASE=seed` first and `verify` second. The second invocation requires a different process ID and reads the existing encrypted snapshot with the existing Keychain key; it never reinitializes the identity. Verification removes the fixture. A reused seed ID with an existing manifest is rejected.

Example using XcodeBuildMCP `test_sim` (or `test_device` when available): set `testRunnerEnv` to these values and use `extraArgs` containing `-parallel-testing-enabled`, `NO`, and `-only-testing:XMPPiOSLifecycleTests/EncryptionLifecycleTests/testIdentityAcrossSeparateProcessLaunches`. Configure the XMPPiOSLifecycle scheme and the desired simulator or physical destination first.

## Attended physical lock probe

Run only `testLockedDeviceCanReadAfterFirstUnlockEncryptionState` on an unlocked, passcode-protected physical iPhone. The passcode/lock policy must make protected data unavailable promptly. Set test-runner environment `XMPP_LIFECYCLE_MANUAL_LOCK=1`.

The test emits and attaches **LOCK_PROBE_ARMED** after both peer profiles are initialized, fingerprints approved in the isolated fixture and both ciphertext packets prepared. All expensive setup occurs before arming. Lock the phone immediately, keep it locked, and allow up to 25 seconds. The test obtains a finite UIKit background task; it does not request indefinite execution. Success requires all of the following observed in the same run:

1. `UIApplication.isProtectedDataAvailable` becomes false.
2. A separately created `.complete` protection sentinel can no longer be read.
3. The `.afterFirstUnlockThisDeviceOnly` Keychain item is retrieved successfully.
4. A newly opened class-C SQLite connection and fresh OMEMO service restore the existing identity, decrypt one preprepared legacy packet and one modern packet from an approved generated peer, and atomically commit plaintext, ratchet changes and replay outcomes while the device remains locked. Every attempted network operation throws.
5. Repeating those same packets leaves the snapshot unchanged, and the device ID/fingerprint is unchanged.

**LOCK_PROBE_VERIFIED** is emitted only after these checks. A timeout is a failure, not a claimed pass. Simulator runs always skip this probe. No private selector, undocumented HID command or fabricated lock state is used. Background task expiration or a debugger/device policy preventing a real lock can make the probe fail or terminate; rerun attended and preserve its result bundle.

This covers relock **after first unlock**. It does not establish behavior before the first unlock following a reboot, device-to-device restoration, push/NSE execution, background scheduling reliability or APNs delivery. Those remain separate lifecycle/operational scenarios.

## Primary references

Accessed 2026-09-14:

- [After-first-unlock, this-device-only Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly): key remains accessible after the first unlock until restart and does not migrate to another device.
- [Complete-until-first-user-authentication file protection](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication): class-C files remain available after a subsequent lock.
- [UIApplication protected-data availability](https://developer.apple.com/documentation/uikit/uiapplication/isprotecteddataavailable): relevant to complete/complete-unless-open protection, not a promise that class-C data becomes inaccessible.
- [Finite background task API](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)): requests bounded continuation of work.
- [XCUIDevice public API](https://developer.apple.com/documentation/xcuiautomation/xcuidevice): documented hardware-button simulation includes home, volume, camera and action buttons; no public lock button is documented.

## Verified locally

2026-09-14 simulator baseline: three tests passed, zero failed; three opt-in/physical tests skipped. Separate seed and verify invocations each passed with zero skips, proving actual test-host process relaunch on simulator. A subsequent physical-iPhone run passed all four standard checks with zero failures (the attended lock and separate-process tests were intentionally skipped in the baseline). Separate physical seed and verify invocations then each passed without skips. Evidence is retained outside git under `work/omemo-device/lifecycle-standard.xcresult`, `lifecycle-relaunch-seed.xcresult` and `lifecycle-relaunch-verify.xcresult` with corresponding logs. The physical tests verified actual directory/SQLite-sidecar protection metadata and a separate-process Keychain-backed identity restore. **No physical locked-device run has been performed by this diagnostic task.**

The physical invocations used `xcodebuild test` for the initial build and `test-without-building` for the two relaunch phases, scheme `XMPPiOSLifecycle`, a dedicated `work/LifecycleDeviceDerivedData` directory and `-parallel-testing-enabled NO`. Xcode propagates variables prefixed `TEST_RUNNER_` to the hosted test process; set `TEST_RUNNER_XMPP_LIFECYCLE_RUN_ID` and `TEST_RUNNER_XMPP_LIFECYCLE_PHASE` for shell-driven seed/verify runs. Device destination and development team are local configuration and are deliberately not committed here.

The strengthened dual-profile receive/commit path also has an ordinary unlocked regression, `testPreparedIncomingPacketsCommitUsingOnlyPersistentIdentity`, which passed on simulator. The attended probe calls the exact same helper after proving physical lock; an unlocked helper pass is not a locked-device result. Rebuild the device test product after changing this helper before running the attended probe.
