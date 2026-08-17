# InfraPulse Development Guidelines

## Scope

InfraPulse is a native SwiftUI macOS menu-bar app. It currently monitors AWS
Login sessions and is intended to grow into a broader infrastructure monitor.
The minimum supported macOS version is 13.0.

## Project layout

All sources live in `Sources/InfraPulse/`, one top-level type per file:

- `main.swift` is the entry point only. Swift allows top-level code in this
  file alone, so it must stay minimal rather than accumulate declarations.
- `InfraPulseApp.swift` is the SwiftUI `App` and the menu-bar scene.
- `AppModel.swift` holds the observable state and the monitoring loop. The
  work it drives lives in stateless namespaces it calls into: `AWSSession`
  (AWS CLI and login introspection), `KubernetesClient` (kubectl),
  `VPNDetector` (VPN and office network), `ReleaseVersion` (update
  comparison) and `UpdateInstaller` (running the Homebrew upgrade). Keep new
  external-command work in those, not in `AppModel`.
- `UpdateInstaller.swift` runs `brew upgrade` as its own LaunchAgent, not as a
  child of the app, and leaves the outcome in a file the next launch reports.
- `AppDelegate.swift` handles application lifecycle, notably reopen.
- `SingleInstanceGuard.swift` enforces one running instance.
- `MenuContent.swift` is the popover body, reused by the status window.
- `SettingsView.swift`, `StatusWindowController.swift` and
  `SettingsWindowController.swift` cover the two windows.
- `StatusTypes.swift` holds `SessionStatus`, `VPNState`, `KubernetesState`
  and `AppAlert`; `AppResources.swift` holds shared constants and icon lookup.
- `Resources/` contains the application and menu-bar icons.

Swift scopes `private` to a file, so splitting a type across files silently
widens access. Keep each type whole in its own file instead.
- `Info.plist` defines the bundle metadata and current app version.
- `com.infrapulse.plist.template` defines the user LaunchAgent used
  by the Homebrew cask.
- `package-app.sh` builds the universal app bundle and release ZIP.
- `Makefile` provides package verification and the release workflow.

## Development rules

- Preserve the native SwiftUI/AppKit experience and macOS 13 compatibility.
- Keep user-facing terminology consistent: `AWS`, `AWS Login`, `Run AWS Login`,
  `Expiry`, `Settings`, and `Quit InfraPulse`.
- Do not reintroduce static AWS credentials. AWS CLI and temporary session
  credentials are the only authentication path.
- The selected AWS profile is persisted in UserDefaults. The LaunchAgent must
  not hard-code `default`; it should allow the app’s saved profile to be used.
- Keep the LaunchAgent’s `KeepAlive` behavior in mind: Quit must unload the
  current session’s LaunchAgent before terminating the app.
- Preserve the separation between the menu-bar app and the external AWS Login
  dialog behavior.
- Detecting quickly that AWS credentials stopped working is the point of the
  app; tools like Lens and MCP servers fail silently when they expire. No wait
  in the monitor loop may sit on a timer through an event that would change its
  answer, so a wake or a returning network sets `forceAccessCheck` and every
  sleep goes through `sleepUntilDue`. A blind backoff once hid an expiry for
  five minutes after the lid opened.
- `status` has two writers: the monitor loop, which asks AWS, and the one-second
  clock, which only knows the time left. Derive the clock's answer in one
  expression and let a spent countdown defer to the loop, or the two flap.
- Detection speed and notification cadence are separate; make detection faster,
  not the dialog more frequent. The dialog names what broke — AI agents, MCP
  servers, Lens and kubectl fail silently — because that is the head-scratching
  it exists to prevent. Dismissing it ends the nagging for that expiry cycle;
  only a dialog that timed out unseen re-notifies, every `reNotifyInterval`. A
  working session arms the next cycle.
- Only one InfraPulse may run at a time. `SingleInstanceGuard` enforces this
  with an advisory `flock`, because the LaunchAgent execs the binary directly
  and so bypasses LaunchServices' bundle-level deduplication.
- Opening InfraPulse while it is running must open the status window
  (`StatusWindowController`), which hosts the same `MenuContent` as the
  menu-bar popover. Two paths reach it and both must keep working: Finder,
  Spotlight and the Dock send a reopen event to `AppDelegate`, while execing
  the binary starts a real process that exits on the lock and notifies the
  running instance.
- Keep `AppDelegate` attached with `@NSApplicationDelegateAdaptor`. SwiftUI
  overwrites a delegate assigned directly to `NSApplication.shared.delegate`,
  which silently disables every callback on it.
- Do not commit secrets, certificates, private keys, p12 files, or passwords.

## Build and verify

Build the debug app:

```bash
swift build -c debug
```

Stop the installed LaunchAgent, build, and run the local debug version:

```bash
make run
```

To test another AWS profile:

```bash
make run PROFILE=teamB
```

Debug output is written to `/private/tmp/infrapulse-debug.log`.

`make run` reports its version as `dev` and prints every live InfraPulse
process, so a local build is never confused with an installed release.
`make stop` also kills the installed app, which LaunchServices registers as
`application.com.infrapulse.*` rather than under the LaunchAgent
label.

Build and package the universal release ZIP:

```bash
./package-app.sh
```

Verify the package and archive checksum:

```bash
make check
```

The package must contain `InfraPulse.app`, its SwiftPM resource bundle,
`darkAppIcon.png`, and `com.infrapulse.plist` at the ZIP root.

## AWS profile behavior

The app starts with the saved profile, falling back to `default`. A command
line profile argument remains supported for local testing:

```bash
.build/debug/InfraPulse teamB
```

Settings discovers profiles using `aws configure list-profiles`. Changing the
profile must reset the current monitor state and start monitoring the selected
profile immediately.

## Release workflow

Commit all intended code changes first and ensure the InfraPulse repository is
clean. Then run:

```bash
make release
```

The release workflow increments the patch version, builds and publishes that
new version, updates and pushes the private Homebrew cask, then commits and
pushes the new version to the InfraPulse repository. If publishing fails, the
version is restored.

The workflow uses:

- `RELEASE_REPO`, defaulting to `sunil-saini/homebrew-tools`
- `TAP_DIR`, defaulting to `/private/tmp/homebrew-tools`

Do not use `make -n release`: the Makefile invokes a recursive make command,
which can still execute release steps during a dry run. The cask should point
to an immutable GitHub release asset and its SHA256 must match the ZIP.

After a release, sync a local Homebrew tap checkout before testing:

```bash
make sync-tap
make install
```
