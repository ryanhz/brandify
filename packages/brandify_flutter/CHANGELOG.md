## 0.3.0

- Renders the Google Play feature graphic for `brandify frame` (frame job v2): 1024×500, the logo on
  the left and the name and subtitle on the right, or the text alone, centred; text shrinks to fit
  inside the edges. Needs brandify 0.3.0.

## 0.2.2

- No changes; released alongside brandify 0.2.2 so both packages keep the same version.

## 0.2.1

- Imports `package:flutter/widgets.dart` instead of `material.dart`, which Flutter 3.50 deprecates.
  Works the same on every supported Flutter.

## 0.2.0

No API changes. Released alongside brandify 0.2.0; use both packages at the same version.

## 0.1.0

First release.

- `brandifyTest` and `shot(name, keyboard: …)`: the device side of `brandify capture`. Sets the
  capture locale, settles the UI, controls the soft keyboard, and runs with the `fullyLive` frame
  policy so native views (`PlatformView`) are drawn.
- `package:brandify_flutter/frame.dart`: the slide compositor `brandify frame` runs, based on
  app_deploy_screenshots' `MarketingFrame`.
