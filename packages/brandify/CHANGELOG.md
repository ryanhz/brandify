## 0.2.1

- README: a table of every command at the top, with `rename`, `icons` and `metadata` alongside the
  screenshot steps; the package description covers them too.

## 0.2.0

From an unbranded app to a branded store presence: fill in `brandify.yaml`, then run one command
for each part.

- `brandify init` also writes an `app:` block (`name`, `android_package`, `ios_bundle_id`,
  `logo_path`) and a `metadata:` block per locale (`name`, `subtitle`, `description`, `keywords`,
  `release_notes`), empty and commented. It still doesn't prompt; empty fields never stop a capture.
- New `brandify rename`: sets the display name, Android package and iOS bundle ID from `app:`.
  brandify edits the files itself, with no external tool: `applicationId` and `namespace` (Groovy
  or Kotlin DSL), the Kotlin/Java sources moved to the new package, `android:label`,
  `PRODUCT_BUNDLE_IDENTIFIER` (keeping `<id>.RunnerTests`) and `CFBundleDisplayName`. Android and
  iOS IDs may differ. Without `--force` it is a dry run that lists every change; it refuses what
  it can't change safely (flavors, IDs from build settings) before touching a file.
- New `brandify icons`: Android and iOS launcher icons from `app.logo_path`, made by
  `flutter_launcher_icons` (a dev dependency of your app) from a config brandify writes to
  `build/brandify/`.
- New `brandify metadata`: writes `metadata:` as the text files fastlane `deliver` (App Store) and
  `supply` (Google Play) upload, with the Play changelog named after the versionCode. It checks
  required fields and store length limits for every locale before writing, and replaces or deletes
  only files it wrote, recorded in `fastlane/.brandify-export.json` (shared with export).
- `brandify.yaml` is checked when it loads: `app:` IDs must be well formed, and `metadata:`
  locales must be in `locales`. Each command names any required field that is missing.
- `brandify doctor` also checks `app:`, the logo and `metadata:`, as warnings.

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
