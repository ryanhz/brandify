# brandify

**Status: pre-release.** Capture works on Android emulators and iOS simulators; framing works
(verified on Android captures); store export is in progress.

brandify turns your Flutter app into store screenshots taken from a **real simulator or emulator**,
driven by an `integration_test` script and run unattended with one command:

```bash
dart run brandify capture
```

## Why real capture

If your app embeds native views (`PlatformView`: native 3D, maps, camera previews, native ads, WebView,
video players), **widget-test rendering gives you a black hole and doesn't tell you.** In our evaluation
on a production Flutter app with native 3D rendering via `PlatformView`, app_deploy_screenshots rendered the 3D region as solid `#000000`,
with no placeholder and no warning, and wrote the PNG before the `MissingPluginException` surfaced. The
widget-test environment has no `flutter/platform_views` implementation on either platform.

brandify captures the device's screen from the host (`adb exec-out screencap`,
`xcrun simctl io screenshot`), so you get:

- **native views**, rendered by the platform;
- the **real system bars** (cleaned up: 9:41, full battery, no notifications) and the real gesture pill;
- the **real device geometry**, and the real keyboard when you ask for it;
- **no Android surface swap** (`convertFlutterSurfaceToImage`), which in-app screenshots need.

What it does **not** give you is sharper Flutter pixels. For plain Flutter content, a widget test with
the right device geometry renders almost the same pixels and is much faster.

## Evidence

- **Native views:** the evaluation above, on a production Flutter app with native 3D rendering.
- **Deterministic:** two full runs, each from a **cold emulator boot** (boot, build, 2 locales × 3
  screens, shutdown; 89 s and 78 s), produced **byte-identical PNGs**: all 6 files, every byte.
- **iOS too:** on an iPhone 17 Pro Max simulator (iOS 26.4, Xcode 27.0), 2 locales × 3 screens at
  1320×2868 (the App Store 6.9" slot), clean 9:41 status bar, 2–3 captures per shot including a real
  keyboard animation.
- **The real status bar survives framing:** a real 1080×2400 capture framed onto Google Play's
  1080×1920 canvas keeps the device's own status bar and gesture pill, with nothing drawn on top.
- **Honest about Flutter pixels:** against a widget test with matched geometry, 0.56 % of app-content
  pixels differ slightly and 0.03 % strongly (text antialiasing).

## Requirements

- **Flutter 3.35.3 or newer (Dart 3.9).** `brandify_flutter` depends on
  [app_deploy_screenshots](https://pub.dev/packages/app_deploy_screenshots) `^1.2.1` for framing,
  which sets this floor.
- Android: the Android SDK (emulator, platform-tools) and an AVD.
- iOS: macOS with Xcode and an iOS simulator runtime.

## Usage (current)

`brandify.yaml` next to your `pubspec.yaml`:

```yaml
locales: [en-US, de-DE]
devices:
  - id: pixel
    platform: android
    avd: Pixel_8_API_36        # booted headless if not running
  - id: iphone69
    platform: ios
    simulator: iPhone 17 Pro Max
```

`integration_test/brandify_test.dart`, with `brandify_flutter` as a dev dependency:

```dart
import 'package:brandify_flutter/brandify_flutter.dart';

void main() {
  brandifyTest('store screenshots', (tester, shot) async {
    await tester.pumpWidget(const MyApp());
    await shot('home');
    await tester.tap(find.byKey(const Key('add_task')));
    await tester.enterText(find.byType(TextField), 'Buy oat milk');
    await shot('add_task', keyboard: Keyboard.show);
  });
}
```

Raw screenshots and a manifest land in `build/brandify/raw/<device>/<locale>/`.

### Framing

```bash
dart run brandify frame
```

Frames every raw capture for its store slot (Android: Google Play phone, 9:16 at the capture's width,
e.g. 1080×1920; iOS: the App Store display class whose size the capture already has, e.g. 6.9"
1320×2868) into `build/brandify/framed/<device>/<locale>/`. Optional `frame:` section:

```yaml
frame:
  template: caption_top                # the slide design (the only one so far)
  caption_area: auto                   # or a share of the height above the phone, e.g. 0.25
  background: ['#0B1F3A', '#2E5BFF']   # one colour, or a top-to-bottom gradient
  device: screen                       # or bezel
  font: fonts/NotoSansSC-Bold.ttf      # caption font, e.g. for CJK
  captions:                            # none, or one per captured locale and shot
    en-US:
      home: {headline: Everything in one place, subheadline: Plan your day in seconds}
      add_task: Add a task             # headline only
```

`caption_top` puts the caption at the top and the whole phone below it, above a bottom margin. Every
slide of a device shows the phone at the same size and place, in every locale: the caption area is
as tall as the device's tallest caption (`auto`), or the share you set. A caption taller than a set
`caption_area` is an error that names the slide, rather than a smaller phone on that slide.

The compositor is [app_deploy_screenshots](https://pub.dev/packages/app_deploy_screenshots)'
`MarketingFrame`, run in a widget test brandify generates on the host. The screen it frames is the
real capture, re-rendered pixel for pixel; brandify never draws a status bar or camera cutout over it.
