import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../config.dart';
import '../logger.dart';
import '../png.dart';
import '../process.dart';
import '../store/slots.dart';

/// Version of the job file read by `package:brandify_flutter/frame.dart`.
/// Keep in sync with `frameJobVersion` there.
const frameJobVersion = 2;

/// One raw capture to frame.
class FrameItem {
  FrameItem({
    required this.device,
    required this.locale,
    required this.shot,
    required this.platform,
    required this.raw,
    required this.out,
    required this.width,
    required this.height,
    required this.dpr,
    required this.slot,
    this.caption,
  });

  final String device;
  final String locale;
  final String shot;
  final DevicePlatform platform;

  /// Absolute paths.
  final String raw;
  final String out;

  /// Capture size in pixels and the device's pixel ratio, as the app saw it.
  final int width;
  final int height;
  final double dpr;
  final StoreSlot slot;
  final Caption? caption;

  Map<String, Object?> toJson() => {
        'device': device,
        'locale': locale,
        'shot': shot,
        'platform': platform.name,
        'raw': raw,
        'out': out,
        'width': width,
        'height': height,
        'dpr': dpr,
        'slot': slot.id,
        'canvas': {'width': slot.width, 'height': slot.height},
        if (caption != null) 'caption': caption!.toJson(),
      };
}

/// One locale's Google Play feature graphic to render.
class FeatureGraphicItem {
  FeatureGraphicItem({required this.locale, required this.out, required this.caption});
  final String locale;

  /// Absolute.
  final String out;
  final Caption caption;

  Map<String, Object?> toJson() => {'locale': locale, 'out': out, 'text': caption.toJson()};
}

/// Folder under `frame.output` for feature graphics; can't be a device id.
const featureGraphicFolder = '_feature_graphic';

class FrameJob {
  FrameJob(this.items, this.style, {this.featureGraphics = const [], this.featureGraphicStyle = const {}});
  final List<FrameItem> items;
  final List<FeatureGraphicItem> featureGraphics;

  /// `background`, `text_color` (ARGB ints), `logo`, `font` (paths or absent).
  final Map<String, Object?> featureGraphicStyle;

  /// `template`, `caption_area`, `background` (ARGB ints), `device`
  /// (`screen`/`bezel`), `font` (path).
  final Map<String, Object?> style;

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'brandify_frame_job': frameJobVersion,
        'style': style,
        'items': [for (final i in items) i.toJson()],
        if (featureGraphics.isNotEmpty)
          'feature_graphic': {
            'style': featureGraphicStyle,
            'items': [for (final f in featureGraphics) f.toJson()],
          },
      });

  /// Reads the capture manifests under `capture.output` and pairs every shot
  /// with its store slot and caption.
  ///
  /// With no [devices]/[locales] filter, device/locale pairs that have no
  /// capture yet are skipped with a note; named ones must exist.
  static FrameJob build(BrandifyConfig config,
      {Set<String>? devices, Set<String>? locales, required Logger logger}) {
    final explicit = (devices?.isNotEmpty ?? false) || (locales?.isNotEmpty ?? false);
    final wantDevices = _select('device', config.devices.map((d) => d.id), devices);
    final wantLocales = _select('locale', config.locales, locales);
    final frame = config.frame;

    final items = <FrameItem>[];
    for (final device in config.devices.where((d) => wantDevices.contains(d.id))) {
      for (final locale in config.locales.where(wantLocales.contains)) {
        final dir = p.join(config.outputDir, device.id, locale);
        final manifestFile = File(p.join(dir, 'manifest.json'));
        if (!manifestFile.existsSync()) {
          if (explicit) {
            throw BrandifyException('No capture for ${device.id} $locale at '
                '${p.relative(dir)}. Run `brandify capture -d ${device.id} -l $locale` first.');
          }
          logger.info('[${device.id} $locale] no capture yet; skipped');
          continue;
        }
        items.addAll(_itemsFor(config, device, locale, dir, manifestFile, logger));
      }
    }
    final wantsAndroid = config.devices.any((d) => wantDevices.contains(d.id) && d.platform == DevicePlatform.android);
    final graphics = config.featureGraphic == null || !wantsAndroid
        ? const <FeatureGraphicItem>[]
        : featureGraphicItems(config, config.locales.where(wantLocales.contains), logger);
    if (items.isEmpty && graphics.isEmpty) {
      throw BrandifyException(
          'Nothing to frame: no captures under ${p.relative(config.outputDir)}. Run `brandify capture` first.');
    }

    final font = frame.font == null ? null : p.normalize(p.join(config.root, frame.font!));
    if (font != null && !File(font).existsSync()) {
      throw BrandifyException('frame.font: ${frame.font} not found in ${config.root}.');
    }
    return FrameJob(items, {
      'template': frame.template.id,
      'caption_area': frame.captionArea,
      'background': frame.background,
      'device': frame.device.name,
      if (font != null) 'font': font,
    }, featureGraphics: graphics, featureGraphicStyle: graphics.isEmpty ? const {} : resolveFeatureGraphicStyle(config));
  }

  /// The feature graphics of [locales] (those Google Play lists). Throws if
  /// one has no text.
  static List<FeatureGraphicItem> featureGraphicItems(
      BrandifyConfig config, Iterable<String> locales, Logger logger) {
    final out = <FeatureGraphicItem>[];
    final missing = <String>[];
    for (final locale in locales) {
      if (config.storeLocaleFor(Store.play, locale) == null) continue;
      final caption = config.featureGraphicText(locale);
      if (caption == null) {
        missing.add(locale);
        continue;
      }
      out.add(FeatureGraphicItem(
          locale: locale,
          out: p.join(config.framedDir, featureGraphicFolder, '$locale.png'),
          caption: caption));
    }
    if (missing.isNotEmpty) {
      throw BrandifyException('The feature graphic has no text for ${missing.join(', ')}. Fill in '
          '${missing.map((l) => 'metadata.$l.name').join(', ')} or set feature_graphic.text.');
    }
    return out;
  }

  /// The feature graphic's look, with every default resolved. Throws if a
  /// file it names is missing.
  static Map<String, Object?> resolveFeatureGraphicStyle(BrandifyConfig config) {
    final fg = config.featureGraphic!;
    final background = fg.background ?? config.frame.background;
    final logo = config.featureGraphicLogo;
    if (logo != null && !File(logo).existsSync()) {
      throw BrandifyException('${fg.logo == null ? 'app.logo_path' : 'feature_graphic.logo'}: '
          '${p.relative(logo, from: config.root)} does not exist. Set feature_graphic.logo (`none` for text only).');
    }
    final fontRel = fg.font ?? config.frame.font;
    final font = fontRel == null ? null : p.normalize(p.join(config.root, fontRel));
    if (font != null && !File(font).existsSync()) {
      throw BrandifyException('${fg.font == null ? 'frame.font' : 'feature_graphic.font'}: '
          '$fontRel not found in ${config.root}.');
    }
    return {
      'background': background,
      'text_color': fg.textColor ?? readableOn(background),
      if (logo != null) 'logo': logo,
      if (font != null) 'font': font,
    };
  }

  static List<FrameItem> _itemsFor(BrandifyConfig config, DeviceConfig device,
      String locale, String dir, File manifestFile, Logger logger) {
    final tag = '[${device.id} $locale]';
    final Map<String, Object?> m;
    try {
      m = jsonDecode(manifestFile.readAsStringSync()) as Map<String, Object?>;
    } on FormatException catch (e) {
      throw BrandifyException('$tag ${manifestFile.path} is not valid JSON: ${e.message}');
    }
    final view = m['view'];
    final dpr = view is Map ? (view['dpr'] as num?)?.toDouble() : null;
    if (dpr == null || dpr <= 0) {
      throw BrandifyException('$tag the capture has no device pixel ratio (manifest `view.dpr`); '
          'it was made by an older brandify. Run `brandify capture` again.');
    }

    final shots = [for (final s in (m['shots'] as List? ?? const [])) s as Map];
    final captions = config.frame.captions;
    final byShot = captions[locale];
    if (captions.isNotEmpty) {
      if (byShot == null) {
        throw BrandifyException('$tag frame.captions has no `$locale` entry. Add captions for '
            'every locale, or remove frame.captions to frame without them.');
      }
      final missing = [for (final s in shots) s['name'] as String]
          .where((n) => !byShot.containsKey(n))
          .toList();
      if (missing.isNotEmpty) {
        throw BrandifyException('$tag no caption for ${missing.join(', ')} in frame.captions.$locale.');
      }
      final unused = byShot.keys.where((k) => !shots.any((s) => s['name'] == k)).toList();
      if (unused.isNotEmpty) {
        logger.warn('$tag frame.captions.$locale names ${unused.join(', ')}, which the capture '
            'test never shot (typo?).');
      }
    }

    return [
      for (final s in shots)
        () {
          final name = s['name'] as String;
          final raw = p.join(dir, s['file'] as String);
          final rawFile = File(raw);
          if (!rawFile.existsSync()) {
            throw BrandifyException('$tag $raw is listed in the manifest but missing.');
          }
          final head = rawFile.openSync();
          final size = pngSize(head.readSync(32));
          head.closeSync();
          if (size == null) throw BrandifyException('$tag $raw is not a PNG.');
          return FrameItem(
            device: device.id,
            locale: locale,
            shot: name,
            platform: device.platform,
            raw: raw,
            out: p.join(config.framedDir, device.id, locale, '$name.png'),
            width: size.width,
            height: size.height,
            dpr: dpr,
            slot: slotFor(device.platform, size.width, size.height, dpr: dpr),
            caption: byShot?[name],
          );
        }(),
    ];
  }

  /// Opaque white or near-black, whichever reads better on the average of
  /// [background] (ARGB).
  static int readableOn(List<int> background) {
    double channel(int shift) {
      final c = background.map((b) => (b >> shift) & 0xFF).reduce((a, b) => a + b) / background.length / 255;
      return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }

    final luminance = 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0);
    // Contrast with white beats contrast with black below about 0.18.
    return luminance < 0.18 ? 0xFFFFFFFF : 0xFF111111;
  }

  static Set<String> _select(String what, Iterable<String> known, Set<String>? wanted) {
    if (wanted == null || wanted.isEmpty) return known.toSet();
    final unknown = wanted.difference(known.toSet());
    if (unknown.isNotEmpty) {
      throw BrandifyException('Unknown $what ${unknown.join(', ')}. Configured: ${known.join(', ')}.');
    }
    return wanted;
  }
}
