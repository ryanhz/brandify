## 0.1.0

First release.

- `brandify init`: writes `brandify.yaml` and `integration_test/brandify_test.dart` for an existing
  Flutter app, picking an existing AVD. Never overwrites files without `--force`.
- `brandify doctor`: checks Flutter, the project, the Android SDK and AVDs, Xcode and simulators,
  and fastlane, with a fix for each problem. Exits 1 if a capture would fail. `-d` checks only the
  named devices.
- `brandify capture`: boots each AVD / simulator headless, cleans up the status bar, runs the
  capture test once per locale and screenshots the real device screen until two captures match.
  Devices this machine can't run (iOS off macOS, Android without an SDK) are skipped with a
  warning unless named with `-d`. Dependencies are resolved once; tests run with `--no-pub`.
- `brandify frame`: composes store slides (`caption_top` template, gradient background, captions
  per locale, custom font) at the exact Google Play and App Store slot sizes.
- `brandify build`: capture, frame and export in one run, on exactly what was captured; stops at
  the first step that fails and names it.
- Android SDK: found in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, Android Studio's default folder, then
  `PATH`.
- `brandify export`: copies the slides into fastlane's `supply` / `deliver` folders, maps locales to
  each store's codes, checks sizes, counts and alpha, and records what it wrote (with SHA-256) so a
  later export replaces only its own files.
