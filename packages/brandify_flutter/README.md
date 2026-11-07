# brandify_flutter

The Flutter side of [brandify](https://pub.dev/packages/brandify): store screenshots taken from a
**real simulator or emulator**, driven by an `integration_test` script. Native views (`PlatformView`),
the real status bar and the real keyboard all show up, because the device's own screen is captured.

Add it next to the `brandify` command line tool, as dev dependencies at the same version:

```bash
flutter pub add dev:brandify dev:brandify_flutter
dart run brandify init
```

See the [brandify README](https://pub.dev/packages/brandify) for the whole workflow (`init`,
`doctor`, `capture`, `frame`, `export`), the config and the requirements.

## The capture test

`brandifyTest` is a `testWidgets` for `integration_test/brandify_test.dart`. `brandify capture`
runs it once per device and locale; each `shot` asks brandify, on your computer, to screenshot the
device as it is now.

```dart
import 'package:brandify_flutter/brandify_flutter.dart';
import 'package:flutter/material.dart';
import 'package:my_app/main.dart' as app;

void main() {
  brandifyTest('store screenshots', (tester, shot) async {
    app.main();
    await tester.pumpAndSettle();
    await shot('home');

    await tester.tap(find.byKey(const Key('add_task')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Buy oat milk');
    await shot('add_task', keyboard: Keyboard.show);
  });
}
```

- **Locale:** each run sets the capture's locale (from `brandify.yaml`) as the platform locale, so an
  app with `localizationsDelegates` and `supportedLocales` shows its translated UI. Use
  `parseLocaleTag` to turn a tag such as `zh-Hans` into a `Locale` yourself.
- **Keyboard:** `Keyboard.hide` (the default) hides the soft keyboard and keeps focus,
  `Keyboard.show` shows it for the focused field and waits for it to finish animating,
  `Keyboard.leave` doesn't touch it.
- **Stable frames:** each `shot` waits for `pumpAndSettle` (`settle: false` for screens that never
  settle), then brandify captures until two consecutive screenshots match, so system UI that is still
  animating doesn't end up half-drawn. Native views keep updating, because the test runs with the
  `fullyLive` frame policy. The debug banner is hidden and the text cursor doesn't blink.
- Run it with `dart run brandify capture`. Under plain `flutter test`, shots only settle the UI and
  log their names, which is handy while you write the script.

## Framing

`package:brandify_flutter/frame.dart` is what `brandify frame` runs to compose store slides from the
raw captures. It uses
[app_deploy_screenshots](https://pub.dev/packages/app_deploy_screenshots)' `MarketingFrame` and
re-renders the real capture pixel for pixel. You don't import it yourself.

## Requirements

Flutter 3.35.3 or newer (Dart 3.9), set by app_deploy_screenshots `^1.2.1`.
