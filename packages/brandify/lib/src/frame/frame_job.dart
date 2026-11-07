import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../logger.dart';
import '../png.dart';
import '../process.dart';
import '../store/slots.dart';

/// Version of the job file read by `package:brandify_flutter/frame.dart`.
/// Keep in sync with `frameJobVersion` there.
const frameJobVersion = 1;

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

class FrameJob {
  FrameJob(this.items, this.style);
  final List<FrameItem> items;

  /// `template`, `caption_area`, `background` (ARGB ints), `device`
  /// (`screen`/`bezel`), `font` (path).
  final Map<String, Object?> style;

  String encode() => const JsonEncoder.withIndent('  ').convert({
        'brandify_frame_job': frameJobVersion,
        'style': style,
        'items': [for (final i in items) i.toJson()],
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
    if (items.isEmpty) {
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
    });
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

  static Set<String> _select(String what, Iterable<String> known, Set<String>? wanted) {
    if (wanted == null || wanted.isEmpty) return known.toSet();
    final unknown = wanted.difference(known.toSet());
    if (unknown.isNotEmpty) {
      throw BrandifyException('Unknown $what ${unknown.join(', ')}. Configured: ${known.join(', ')}.');
    }
    return wanted;
  }
}
