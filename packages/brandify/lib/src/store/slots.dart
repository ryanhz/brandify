import '../config.dart';
import '../process.dart';

/// A store screenshot slot: where a framed image is uploaded, and the exact
/// pixel size it must have.
class StoreSlot {
  const StoreSlot(this.id, this.label, this.width, this.height);

  /// Stable key, e.g. `play_phone`, `appstore_iphone_69`.
  final String id;
  final String label;
  final int width;
  final int height;

  @override
  String toString() => '$label ($width×$height)';
}

class _Display {
  const _Display(this.id, this.label, this.sizes);
  final String id;
  final String label;

  /// Portrait sizes App Store Connect accepts for this display class.
  final List<(int, int)> sizes;
}

// App Store Connect screenshot specifications (portrait).
const _appStoreDisplays = [
  _Display('appstore_iphone_69', 'App Store iPhone 6.9"', [(1320, 2868), (1290, 2796), (1260, 2736)]),
  _Display('appstore_iphone_65', 'App Store iPhone 6.5"', [(1284, 2778), (1242, 2688)]),
  _Display('appstore_ipad_13', 'App Store iPad 13"', [(2064, 2752), (2048, 2732)]),
];

/// The slot a raw capture of [width]×[height] from [platform] is framed into.
///
/// - Android: Google Play phone, 9:16 portrait at the capture's width
///   (1080×2400 -> 1080×1920). Play caps the long side at twice the short
///   one, which a 20:9 capture breaks, so framing is what makes it uploadable.
/// - iOS: the App Store display class whose accepted sizes include the
///   capture; the canvas is the capture's own size.
StoreSlot slotFor(DevicePlatform platform, int width, int height) {
  if (width >= height) {
    throw BrandifyException(
        'Capture is $width×$height (landscape). Only portrait screenshots are supported.');
  }
  switch (platform) {
    case DevicePlatform.android:
      final h = (width * 16 / 9).round();
      if (width < 320 || h > 3840) {
        throw BrandifyException(
            'Capture width $width gives a $width×$h Play canvas, outside Play\'s 320–3840 px.');
      }
      return StoreSlot('play_phone', 'Google Play phone', width, h);
    case DevicePlatform.ios:
      for (final d in _appStoreDisplays) {
        if (d.sizes.contains((width, height))) {
          return StoreSlot(d.id, d.label, width, height);
        }
      }
      throw BrandifyException(
          'No App Store screenshot slot takes $width×$height. Capture on an iPhone 6.9" '
          'simulator (e.g. iPhone 17 Pro Max, 1320×2868) or a 13" iPad.');
  }
}
