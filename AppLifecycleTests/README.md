# Lifecycle tests

Run the **HausXMPPLifecycle** scheme. It hosts `HausXMPPLifecycleTests` inside the app, uses an isolated UI storage namespace, and creates only generated synthetic account and key fixtures under `Application Support/Messaging/LifecycleTests`. There are no network calls and no reads of a real account. Ordinary fixtures and their dedicated Keychain items are deleted after each test. The separate-process seed persists until its matching verification run.

```bash
xcodebuild test -project HausXMPP.xcodeproj -scheme HausXMPPLifecycle \
  -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath build/DerivedData \
  -parallel-testing-enabled NO
```

Besides the app logic tests (conversation presentation, timeline, composer, notifications, migrations), the encryption suite checks device-local Keychain accessibility metadata, stable key reload, encrypted OMEMO identity restoration, backup exclusion and fail-closed behaviour after a wrapping key disappears. A device-only test checks the actual Data Protection class on the directory, the SQLite database, its WAL and SHM files and the transport lock file. Simulator runs skip that assertion because the simulator file system does not expose iOS Data Protection attributes.

Rebuild with this scheme before running it. A derived data folder last built by the `HausXMPP` scheme makes about a dozen unrelated tests that compare errors fail.

## Process relaunch

Run only `HausXMPPLifecycleTests/EncryptionLifecycleTests/testIdentityAcrossSeparateProcessLaunches`, twice, in separate test invocations. Give both the same fresh UUID as `XMPP_LIFECYCLE_RUN_ID`, with `XMPP_LIFECYCLE_PHASE=seed` the first time and `verify` the second. Xcode passes variables prefixed `TEST_RUNNER_` to the hosted test process, so from a shell:

```bash
export TEST_RUNNER_XMPP_LIFECYCLE_RUN_ID=$(uuidgen) TEST_RUNNER_XMPP_LIFECYCLE_PHASE=seed
xcodebuild test ... -only-testing:HausXMPPLifecycleTests/EncryptionLifecycleTests/testIdentityAcrossSeparateProcessLaunches
export TEST_RUNNER_XMPP_LIFECYCLE_PHASE=verify
xcodebuild test-without-building ... -only-testing:HausXMPPLifecycleTests/EncryptionLifecycleTests/testIdentityAcrossSeparateProcessLaunches
```

The second invocation requires a different process ID and reads the existing encrypted snapshot with the existing Keychain key; it never initialises a new identity. Verification removes the fixture. A reused seed ID with an existing manifest is rejected.

## Attended lock probe (device only)

Run only `testLockedDeviceCanReadAfterFirstUnlockEncryptionState` on an unlocked, passcode-protected iPhone whose lock settings make protected data unavailable promptly. Set `XMPP_LIFECYCLE_MANUAL_LOCK=1`. Device runs need a development team (`DEVELOPMENT_TEAM` in `Config/Local.xcconfig`).

The test emits and attaches **LOCK_PROBE_ARMED** after both OMEMO profiles are initialised, fingerprints approved in the isolated fixture and both ciphertext packets prepared. All expensive setup happens before that. Lock the phone immediately, keep it locked, and allow up to 25 seconds. The test uses a finite UIKit background task. It passes only if all of the following hold in the same run:

1. `UIApplication.isProtectedDataAvailable` becomes false.
2. A separately created `.complete` protection sentinel can no longer be read.
3. The `.afterFirstUnlockThisDeviceOnly` Keychain item is still read successfully.
4. A newly opened class C SQLite connection and a fresh OMEMO service restore the existing identity, decrypt one prepared legacy packet and one modern packet from an approved generated peer, and atomically commit plaintext, ratchet changes and replay outcomes while the device stays locked. Every attempted network operation throws.
5. Repeating the same packets leaves the snapshot unchanged, and the device ID and fingerprint are unchanged.

**LOCK_PROBE_VERIFIED** is emitted only after these checks. A timeout is a failure. Simulator runs always skip this probe. No private API or simulated lock state is used, so background task expiry or a debugger that keeps the device awake can make the probe fail; run it again attended.

The probe covers relocking after the first unlock. It does not cover behaviour before the first unlock after a reboot, restoring to another device, the notification service extension, background scheduling or APNs delivery.

`testPreparedIncomingPacketsCommitUsingOnlyPersistentIdentity` runs the same receive and commit helper unlocked, on the simulator too. A pass there is not a locked-device result. Rebuild the device test product after changing that helper and before running the probe.

## Notification checks

`NotificationAccessGateTests` uses disposable files to check that a signed-out account's notifications stay off across relaunches, that turning them on removes the marker, that an empty marker stays off and that unreadable state throws. `PushTokenCallbackTests` feeds synthetic APNs callback bytes to the test host to check that the latest token is buffered and stale tokens are rejected; it never requests a real token. `NotificationNavigationTests` covers a buffered cold-launch tap and ignored dismiss and malformed callbacks. Account and message authorisation for notifications is tested in MessagingCore.

## References

Accessed 2026-09-14:

- [After-first-unlock, this-device-only Keychain accessibility](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly): the key stays accessible after the first unlock until restart and does not migrate to another device.
- [Complete-until-first-user-authentication file protection](https://developer.apple.com/documentation/foundation/fileprotectiontype/completeuntilfirstuserauthentication): class C files stay available after a later lock.
- [UIApplication protected-data availability](https://developer.apple.com/documentation/uikit/uiapplication/isprotecteddataavailable): relevant to complete and complete-unless-open protection, not a promise that class C data becomes inaccessible.
- [Finite background task API](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(withname:expirationhandler:)): requests bounded continuation of work.
- [XCUIDevice](https://developer.apple.com/documentation/xcuiautomation/xcuidevice): the documented hardware-button simulation has no lock button.
