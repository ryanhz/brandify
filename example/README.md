# brandify_example

A small task app ("Acme Tasks") for trying brandify end to end:

```bash
cd example
dart run brandify capture   # raw screenshots -> build/brandify/raw/<device>/<locale>/
dart run brandify frame     # store images   -> build/brandify/framed/<device>/<locale>/
```

Devices, locales and captions are in [`brandify.yaml`](brandify.yaml); the capture script is
[`integration_test/brandify_test.dart`](integration_test/brandify_test.dart).

## A native view on the home screen

The "focused this week" card is **not** Flutter: it's a `PlatformView` drawn by the platform
(Android `Canvas` in [`MainActivity.kt`](android/app/src/main/kotlin/dev/brandify/brandify_example/MainActivity.kt),
UIKit Core Graphics in [`AppDelegate.swift`](ios/Runner/AppDelegate.swift)). Its subtitle names the
renderer that drew it.

brandify captures the device's real screen, so the card shows up in the screenshots. Widget-test
screenshot tools have no platform views: the same area comes out blank, with no warning.

## English only, by design

The app's UI strings are hard-coded English, and it has no `localizationsDelegates`. Captures for
other locales (e.g. `de-DE`) therefore show English app UI; only the framing captions in
`brandify.yaml` are translated. This is a limit of the example app, not of brandify: in your app,
`brandifyTest` sets each capture's locale as the platform locale, so an app with
`localizationsDelegates` and `supportedLocales` shows its translated UI.
