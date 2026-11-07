## 0.1.0

First release.

- `brandifyTest` and `shot(name, keyboard: …)`: the device side of `brandify capture`. Sets the
  capture locale, settles the UI, controls the soft keyboard, and runs with the `fullyLive` frame
  policy so native views (`PlatformView`) are drawn.
- `package:brandify_flutter/frame.dart`: the slide compositor `brandify frame` runs, based on
  app_deploy_screenshots' `MarketingFrame`.
