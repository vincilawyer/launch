# Contributing to Launch

Thank you for helping improve Launch.

## Before opening a change

- Use macOS 14 or later with the current Xcode or Command Line Tools.
- Keep the project dependency-free unless a dependency has a clear maintenance
  and security advantage.
- Read `AGENTS.md`, especially the persistence, drag-and-drop, gesture and
  WeChat transaction invariants.
- Keep unrelated formatting or generated files out of the change.

## Testing

Run:

```sh
./scripts/run-tests.sh
./scripts/build-app.sh
```

Changes to layout, preferences, scanning, gestures or transactions need a
focused regression in the corresponding executable check suite. UI interaction
changes should also include the relevant manual acceptance result in the pull
request description.

Never test by modifying the user's real applications, Dock settings or trackpad
preferences. WeChat companion tests must use temporary fixture bundles.

## Pull requests

Explain:

1. The user-visible problem and intended behavior.
2. The important safety or compatibility trade-offs.
3. Automated tests run.
4. Manual macOS scenarios verified.

Launch uses a version-gated private MultitouchSupport fallback. Do not broaden
its operating-system allowlist without verifying the ABI and real hardware on
every added build. Do not describe an observational event path as a supported
way to suppress Mission Control, App Exposé or Spaces.

By contributing, you agree that your contribution is licensed under the MIT
License in this repository.
