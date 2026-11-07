import '../config.dart';
import '../process.dart';

enum Store {
  play('Google Play'),
  appStore('App Store');

  const Store(this.label);
  final String label;
}

/// A store screenshot slot: where a framed image is uploaded, the exact
/// pixel size it has, and how many the store takes.
class StoreSlot {
  const StoreSlot(this.id, this.label, this.store, this.width, this.height,
      {required this.maxCount, this.fastlaneFolder});

  /// Stable key, e.g. `play_phone`, `appstore_iphone_69`.
  final String id;
  final String label;
  final Store store;

  /// The canvas: framed images for this slot are exactly this size.
  final int width;
  final int height;

  /// Most screenshots the store takes per locale for this slot.
  final int maxCount;

  /// Play only: the `supply` folder under `images/` (e.g. `phoneScreenshots`).
  /// App Store slots have none: `deliver` tells them apart by pixel size.
  final String? fastlaneFolder;

  @override
  String toString() => '$label ($width×$height)';
}

// ---------------------------------------------------------------------------
// Google Play
//
// Every screenshot: JPEG or 24-bit PNG (no alpha), at most 8 MB, each side
// 320–3840 px, the long side at most twice the short one, up to 8 per device
// type. Tablet sets (7", 10") are separate folders in `supply`.
// ---------------------------------------------------------------------------

const playMaxBytes = 8 * 1024 * 1024;
const playMinSide = 320;
const playMaxSide = 3840;
const playMaxCount = 8;

/// The Android classes, by the device's smallest width in dp.
enum PlayClass {
  phone('play_phone', 'Google Play phone', 'phoneScreenshots'),
  tablet7('play_tablet_7', 'Google Play 7" tablet', 'sevenInchScreenshots'),
  tablet10('play_tablet_10', 'Google Play 10" tablet', 'tenInchScreenshots');

  const PlayClass(this.id, this.label, this.folder);
  final String id;
  final String label;
  final String folder;

  /// Android's own size buckets: sw600dp is a 7" tablet, sw720dp a 10" one.
  static PlayClass forSmallestWidthDp(double sw) =>
      sw >= 720 ? tablet10 : (sw >= 600 ? tablet7 : phone);
}

// ---------------------------------------------------------------------------
// App Store
//
// The accepted portrait sizes per display class, as App Store Connect and
// fastlane `deliver` (which detects the class from the pixel size) list them.
// Up to 10 per display class and locale; no alpha channel.
// ---------------------------------------------------------------------------

const appStoreMaxCount = 10;

class _Display {
  const _Display(this.id, this.label, this.sizes);
  final String id;
  final String label;
  final List<(int, int)> sizes;
}

const _appStoreDisplays = [
  _Display('appstore_iphone_69', 'App Store iPhone 6.9"', [(1320, 2868), (1290, 2796), (1260, 2736)]),
  _Display('appstore_iphone_65', 'App Store iPhone 6.5"', [(1284, 2778), (1242, 2688)]),
  _Display('appstore_iphone_63', 'App Store iPhone 6.3"', [(1206, 2622), (1179, 2556)]),
  _Display('appstore_iphone_61', 'App Store iPhone 6.1"', [(1170, 2532), (1125, 2436), (1080, 2340)]),
  _Display('appstore_iphone_55', 'App Store iPhone 5.5"', [(1242, 2208)]),
  _Display('appstore_ipad_13', 'App Store iPad 13"', [(2064, 2752), (2048, 2732)]),
  _Display('appstore_ipad_11', 'App Store iPad 11"', [(1488, 2266), (1668, 2420), (1668, 2388), (1640, 2360)]),
];

/// App Store Connect needs one of these iPhone classes; the smaller ones are
/// optional (it scales the large set down).
const appStoreRequiredIphone = {'appstore_iphone_69', 'appstore_iphone_65'};

/// App Store Connect needs the 13" set if the app runs on iPad.
const appStoreRequiredIpad = 'appstore_ipad_13';

bool isIpadSlot(String id) => id.startsWith('appstore_ipad_');

/// The App Store display class that accepts a [width]×[height] image, or
/// null. Portrait only.
StoreSlot? appStoreSlotForSize(int width, int height) {
  for (final d in _appStoreDisplays) {
    if (d.sizes.contains((width, height))) {
      return StoreSlot(d.id, d.label, Store.appStore, width, height, maxCount: appStoreMaxCount);
    }
  }
  return null;
}

/// The slot a raw capture of [width]×[height] from [platform] is framed into.
///
/// - Android: Google Play phone, 7" or 10" tablet by the device's smallest
///   width ([width] / [dpr], in dp; phone if [dpr] is unknown), with a 9:16
///   canvas at the capture's width (1080×2400 -> 1080×1920). Play caps the
///   long side at twice the short one, which a 20:9 capture breaks, so
///   framing is what makes it uploadable.
/// - iOS: the App Store display class whose accepted sizes include the
///   capture; the canvas is the capture's own size.
StoreSlot slotFor(DevicePlatform platform, int width, int height, {double? dpr}) {
  if (width >= height) {
    throw BrandifyException(
        'Capture is $width×$height (landscape). Only portrait screenshots are supported.');
  }
  switch (platform) {
    case DevicePlatform.android:
      final cls = dpr == null || dpr <= 0
          ? PlayClass.phone
          : PlayClass.forSmallestWidthDp(width / dpr);
      final h = (width * 16 / 9).round();
      if (width < playMinSide || h > playMaxSide) {
        throw BrandifyException('Capture width $width gives a $width×$h Play canvas, outside '
            'Play\'s $playMinSide–$playMaxSide px.');
      }
      return StoreSlot(cls.id, cls.label, Store.play, width, h,
          maxCount: playMaxCount, fastlaneFolder: cls.folder);
    case DevicePlatform.ios:
      final slot = appStoreSlotForSize(width, height);
      if (slot != null) return slot;
      throw BrandifyException(
          'No App Store screenshot slot takes $width×$height. Capture on an iPhone 6.9" '
          'simulator (e.g. iPhone 17 Pro Max, 1320×2868) or a 13" iPad.');
  }
}

/// What a written image breaks of [slot]'s store rules; empty if it passes.
/// [hasAlpha]: the PNG has an alpha channel (both stores reject it).
List<String> storeRuleViolations(StoreSlot slot,
    {required int width, required int height, required bool hasAlpha, required int bytes}) {
  final problems = <String>[];
  if (width != slot.width || height != slot.height) {
    problems.add('is $width×$height, but $slot needs ${slot.width}×${slot.height}');
  }
  if (hasAlpha) problems.add('has an alpha channel, which ${slot.store.label} rejects');
  switch (slot.store) {
    case Store.play:
      final short = width < height ? width : height, long = width < height ? height : width;
      if (short < playMinSide || long > playMaxSide) {
        problems.add('has a side outside Play\'s $playMinSide–$playMaxSide px');
      }
      if (long > 2 * short) problems.add('is longer than twice its width, which Play rejects');
      if (bytes > playMaxBytes) {
        problems.add('is ${(bytes / 1024 / 1024).toStringAsFixed(1)} MB, over Play\'s 8 MB');
      }
    case Store.appStore:
      if (appStoreSlotForSize(width, height)?.id != slot.id) {
        problems.add('is not a size App Store Connect accepts for ${slot.label}');
      }
  }
  return problems;
}
