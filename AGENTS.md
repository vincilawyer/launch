# AI maintenance guide

This file applies to the whole repository. Read it before changing Launch.

## Product boundaries

Launch is a native macOS application launcher written in Swift, SwiftUI and
AppKit. It has no package dependencies. It supports macOS 14 or later, while
some global trackpad behavior is intentionally limited to explicitly verified
MultitouchSupport versions.

Do not change the user's Dock preferences, restart Dock, rewrite trackpad
preferences, or claim that Launch can consume macOS Mission Control/Spaces
gestures. Do not ask for Accessibility or Input Monitoring unless a new feature
has a documented, tested need for it. The current Carbon shortcut and local
touch handling do not need either permission.

## Build and verification

Run these from the repository root:

```sh
./scripts/run-tests.sh
./scripts/build-app.sh
./scripts/package-dmg.sh
```

`run-tests.sh` is the required baseline. It builds the app and runs the core,
gesture and menu-bar geometry checks. Some checks need to run outside a
restrictive sandbox because they exercise FSEvents and `iconutil`.

Before a release, also verify the Release build, strict code-signature check,
Info.plist syntax, DMG verification and the manual scenarios listed below.
Never make a real `/Applications` mutation during automated or UI acceptance
tests.

## Architecture map

- `Sources/Launch/Models`: serializable layout, preferences and pure mutation
  state. Keep these types independent of SwiftUI.
- `Sources/Launch/Services/LayoutStore.swift`: the persistence boundary.
- `Sources/Launch/Services/AppScanner.swift`: application discovery and
  localized display-name resolution.
- `Sources/Launch/Controllers/LauncherModel.swift`: main-actor application
  state and the only normal bridge between Views and model mutations.
- `Sources/Launch/Views`: rendering and pointer/keyboard interaction.
- `Sources/Launch/AppDelegate.swift` and `Controllers/LauncherWindowController.swift`:
  process, window, menu-bar item, shortcut and focus lifecycle.
- `Sources/Launch/Services/TrackpadGestureManager.swift`: local touch handling
  plus the version-gated private raw-touch fallback.
- `Sources/Launch/Services/WeChatCompanionRefreshService.swift`: transactional
  creation or replacement of the WeChat companion application.
- `Tests/CoreChecks.swift`, `Tests/GestureChecks.swift` and
  `Tests/MenuBarCoverChecks.swift`: executable regression suites used by the
  project scripts.

## Invariants that must not regress

### Persistence and scanning

- Layout and preferences are one atomic `snapshot.json`; never persist them as
  two independent transactions.
- A failed load must not overwrite a valid or recoverable snapshot with
  defaults.
- An incomplete application scan may merge safe metadata, but must not remove
  applications or folder members from the saved layout.
- Full reconciliation contains each visible installed application at most once.
- Application identity is stable and separate from its localized display name.
  Only real name collisions should invoke the fallback disambiguation rules.

### Layout and drag operations

- Every user drop is one atomic model mutation and one persistence request.
  Do not implement a precise drop as “append, then reorder”.
- A stale target, self-drop, hidden application or missing source is a strict
  no-op. Validate all source and target identities before removing anything.
- `LaunchEntry.id`, `LaunchFolder.id` and application IDs are different
  identities. Preserve entry/folder UUIDs across compaction, reconciliation and
  single-member folder dissolution.
- Pages never exceed `preferences.pageCapacity`. When hiding, uninstalling,
  making a folder or otherwise removing a top-level entry, compact later pages
  forward without changing the existing global order.
- A drag session owns one mouse-down through preview, cross-page movement,
  folder spring-loading and final commit. External state changes cancel and
  quarantine that session until mouse-up; they must not let the same gesture
  create a second session.

### Trackpad and windows

- Page navigation accepts an exact two-finger horizontal sequence. Three or
  more touches block the complete physical sequence until all touches lift.
- A held primary pointer button quarantines touch pagination through all-up, so
  a palm or second finger cannot cancel an icon drag.
- Five-finger open/close is separate from page navigation. Private raw-touch
  code must be version-gated, fail closed and retain a public/local fallback.
  Callback shutdown order and in-flight draining are safety-critical.
- macOS system gestures are observed, not consumed. Keep user-facing guidance
  honest about Mission Control, App Exposé and Spaces conflicts.
- The main Launch panel stays above normal application windows but below Dock.
  The menu-bar cover may cover only the current screen's top inset and must
  never modify or obscure Dock.
- Settings, sheets, menu tracking, app deactivation and delayed gesture tasks
  must have explicit focus/cancellation behavior. A delayed task must not
  re-open Launch after the user's intent changed.

### WeChat companion transaction

- Source is the current, validated main WeChat bundle. Build the companion in a
  same-volume staging location before touching the installed destination.
- Validate bundle IDs, names, signature and generated icon before commit.
- Do not use shell interpolation, `sudo`, forced termination or in-place edits
  of the main WeChat bundle.
- The existing companion remains usable until the new staged bundle is ready.
  Commit and rollback must never leave two registered `.app` bundles with the
  companion bundle ID. A launch failure restores the prior version.
- Tests use temporary fixture bundles only. Never run the real rebuild action as
  part of automated acceptance testing.

## SwiftUI and concurrency guidance

- `LauncherModel` is main-actor isolated. Keep blocking filesystem, process and
  image work off the main actor, then publish results on the main actor.
- High-frequency pointer, geometry and wiggle state belongs in small reference
  objects or leaf views. Do not make the root grid re-render for every mouse or
  touch sample.
- Use one source of truth for a visible control. Lists that filter or regroup
  after a toggle need stable application IDs and live model-derived bindings.
- Long-press, tap and drag recognition must share one state machine; after drag
  or long-press wins, mouse-up must not launch the application.

## Required manual checks

Use an isolated application-support directory and acceptance build whenever
possible. Verify:

1. Short click, long press, edit exit and drag do not conflict.
2. Same-page/cross-page reorder, app-to-app folder creation, spring-loaded
   folder insertion, folder-member reorder and member drag-out persist once.
3. Hide/unhide under an active search updates the switch and grouping instantly.
4. Exact two-finger slow drag and quick flick both page; vertical, three-finger
   and pointer-drag contacts do not.
5. Five-finger open does not leave App Exposé labels over Launch and never
   reappears after focus loss or an explicit hide.
6. Notched and non-notched screens, visible Dock on every edge, page dots,
   errors and enlarged icons do not overlap.
7. Menu-bar icon/shortcut enable, disable, conflict rollback and restart restore
   the persisted state without a transient default shortcut.
8. WeChat context-menu confirmation can be cancelled safely. Do not confirm the
   real rebuild during UI acceptance.

## Generated and release files

`.build/`, `dist/`, `.DS_Store`, local gesture logs and preview images are not
source. Do not commit them. Release archives are produced by scripts after all
checks pass. The current local build is ad-hoc signed; public binary distribution
requires the maintainer's Developer ID signing and Apple notarization. The
private MultitouchSupport path is not suitable for Mac App Store submission.
