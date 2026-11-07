import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../frame/frame_job.dart';
import '../logger.dart';
import '../png.dart';
import '../process.dart';
import '../store/locales.dart';
import '../store/slots.dart';

/// One framed screenshot placed in the fastlane tree.
class ExportedImage {
  ExportedImage(this.item, this.storeLocale, this.path);
  final FrameItem item;

  /// The store's code for the locale, which is also the folder name.
  final String storeLocale;

  /// Absolute path written.
  final String path;
}

/// `brandify export`: copies framed screenshots into the folders fastlane
/// uploads from.
///
/// - Google Play (`supply`):
///   `<output>/metadata/android/<play-locale>/images/<slot>Screenshots/`,
///   with slot `phone`, `sevenInch` or `tenInch`
/// - App Store (`deliver`): `<output>/screenshots/<app-store-locale>/`; deliver
///   tells display classes apart by pixel size.
///
/// Files are `{n}_{name}.png` in capture order (`n` zero-padded when a slot
/// has 10), so both tools upload them in the order the test shot them. With
/// several iOS devices in one App Store locale folder, names get a
/// `{device}_` prefix so they can't collide.
///
/// Everything is planned and checked before anything is touched. The
/// screenshot folders being written belong to brandify: stale images in
/// them (for App Store, those of the display classes being written) are
/// removed, so they never leak into an upload. Text metadata is never
/// touched. After writing, every file is read back and checked against its
/// store's rules.
class FastlaneExporter {
  FastlaneExporter({required this.config, required this.logger});

  final BrandifyConfig config;
  final Logger logger;

  List<ExportedImage> run({Set<String>? devices, Set<String>? locales}) {
    final job = FrameJob.build(config, devices: devices, locales: locales, logger: logger);
    final plan = _plan(job.items);
    if (plan.isEmpty) {
      throw BrandifyException('Nothing to export: every captured locale is set to `none` in export.locales.');
    }
    _clean(plan);
    final written = <ExportedImage>[];
    for (final e in plan) {
      written.add(_write(e));
    }
    _verify(written);
    _report(written);
    return written;
  }

  // -- planning --------------------------------------------------------------

  List<ExportedImage> _plan(List<FrameItem> items) {
    // Framed images must exist, be current and have the slot's size.
    for (final i in items) {
      final tag = '[${i.device} ${i.locale}]';
      final framed = File(i.out);
      if (!framed.existsSync()) {
        throw BrandifyException('$tag "${i.shot}" has no framed image (${p.relative(i.out)}). '
            'Run `brandify frame` first.');
      }
      if (framed.lastModifiedSync().isBefore(File(i.raw).lastModifiedSync())) {
        throw BrandifyException('$tag ${p.relative(i.out)} is older than its capture. '
            'Run `brandify frame` again.');
      }
      final head = framed.openSync();
      final size = pngSize(head.readSync(32));
      head.closeSync();
      if (size == null || size.width != i.slot.width || size.height != i.slot.height) {
        throw BrandifyException('$tag ${p.relative(i.out)} is '
            '${size == null ? 'not a PNG' : '${size.width}×${size.height}'}, but ${i.slot} needs '
            '${i.slot.width}×${i.slot.height}. Run `brandify frame` again.');
      }
    }

    // Store locale per (store, locale); two locales may not share one.
    final codes = <(Store, String), String?>{};
    final owner = <(Store, String), String>{};
    for (final i in items) {
      final store = i.slot.store;
      codes.putIfAbsent((store, i.locale), () {
        final override = config.export.locales[i.locale];
        final code = override != null && override.containsKey(store)
            ? override[store]
            : storeLocale(store, i.locale);
        if (code == null) {
          logger.info('[${i.locale}] export.locales: left out of ${store.label}');
          return null;
        }
        final prev = owner[(store, code)];
        if (prev != null) {
          throw BrandifyException('Locales $prev and ${i.locale} both map to ${store.label} '
              '"$code". Give one of them another code (or `none`) in export.locales.');
        }
        owner[(store, code)] = i.locale;
        return code;
      });
    }

    // Group per store locale and slot, in capture order.
    final groups = <(String, String), List<FrameItem>>{};
    for (final i in items) {
      final code = codes[(i.slot.store, i.locale)];
      if (code == null) continue;
      groups.putIfAbsent((code, i.slot.id), () => []).add(i);
    }

    final iosDevicesPerLocale = <String, Set<String>>{};
    for (final MapEntry(key: (code, _), value: g) in groups.entries) {
      if (g.first.slot.store == Store.appStore) {
        iosDevicesPerLocale.putIfAbsent(code, () => {}).addAll(g.map((i) => i.device));
      }
    }

    final plan = <ExportedImage>[];
    for (final MapEntry(key: (code, _), value: g) in groups.entries) {
      final slot = g.first.slot;
      final devs = {for (final i in g) i.device};
      if (devs.length > 1) {
        throw BrandifyException('Devices ${devs.join(' and ')} both fill $slot for ${slot.store.label} '
            '"$code"; the store keeps one set per slot. Export one of them (`-d`).');
      }
      if (g.length > slot.maxCount) {
        throw BrandifyException('[${g.first.device} ${g.first.locale}] ${g.length} screenshots for '
            '${slot.label}, but ${slot.store.label} takes at most ${slot.maxCount}: '
            '${g.skip(slot.maxCount).map((i) => i.shot).join(', ')} would not upload.');
      }
      final width = '${g.length}'.length;
      final prefix = slot.store == Store.appStore && iosDevicesPerLocale[code]!.length > 1
          ? '${g.first.device}_'
          : '';
      for (final (n, i) in g.indexed) {
        final name = '$prefix${'${n + 1}'.padLeft(width, '0')}_${i.shot}.png';
        plan.add(ExportedImage(i, code, p.join(_folder(slot, code), name)));
      }
    }
    return plan;
  }

  String _folder(StoreSlot slot, String code) => switch (slot.store) {
        Store.play =>
          p.join(config.fastlaneDir, 'metadata', 'android', code, 'images', slot.fastlaneFolder!),
        Store.appStore => p.join(config.fastlaneDir, 'screenshots', code),
      };

  // -- writing ---------------------------------------------------------------

  static final _image = RegExp(r'\.(png|jpe?g)$', caseSensitive: false);

  void _clean(List<ExportedImage> plan) {
    final slotsByFolder = <String, Set<String>>{};
    for (final e in plan) {
      slotsByFolder.putIfAbsent(p.dirname(e.path), () => {}).add(e.item.slot.id);
    }
    slotsByFolder.forEach((folder, slotIds) {
      final dir = Directory(folder);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
        return;
      }
      var removed = 0;
      for (final f in dir.listSync().whereType<File>().where((f) => _image.hasMatch(f.path))) {
        final bool stale;
        if (p.isWithin(p.join(config.fastlaneDir, 'screenshots'), folder)) {
          // deliver's folder mixes display classes: only clear the ones being
          // written, detected by size like deliver does.
          final head = f.openSync();
          final size = pngSize(head.readSync(32));
          head.closeSync();
          stale = size == null ? false : slotIds.contains(appStoreSlotForSize(size.width, size.height)?.id);
        } else {
          stale = true; // supply's per-slot folder belongs to brandify
        }
        if (stale) {
          f.deleteSync();
          removed++;
        }
      }
      if (removed > 0) logger.detail('removed $removed old screenshots from ${p.relative(folder)}');
    });
  }

  ExportedImage _write(ExportedImage e) {
    var bytes = File(e.item.out).readAsBytesSync();
    if (pngHasAlpha(bytes)) {
      final flat = flattenOpaquePng(bytes);
      if (flat == null) {
        throw BrandifyException('[${e.item.device} ${e.item.locale}] ${p.relative(e.item.out)} has '
            'transparent pixels; ${e.item.slot.store.label} needs opaque screenshots. '
            'Use an opaque frame.background.');
      }
      bytes = flat;
    }
    File(e.path).writeAsBytesSync(bytes);
    return e;
  }

  void _verify(List<ExportedImage> written) {
    final problems = <String>[];
    for (final e in written) {
      final Uint8List bytes = File(e.path).readAsBytesSync();
      final size = pngSize(bytes);
      if (size == null) {
        problems.add('${p.relative(e.path)} is not a PNG');
        continue;
      }
      for (final v in storeRuleViolations(e.item.slot,
          width: size.width, height: size.height, hasAlpha: pngHasAlpha(bytes), bytes: bytes.length)) {
        problems.add('${p.relative(e.path)} $v');
      }
    }
    if (problems.isNotEmpty) {
      throw BrandifyException('Exported screenshots break store rules:\n'
          '${problems.map((l) => '  - $l').join('\n')}');
    }
  }

  void _report(List<ExportedImage> written) {
    final groups = <(String, String), List<ExportedImage>>{};
    for (final e in written) {
      groups.putIfAbsent((e.storeLocale, e.item.slot.id), () => []).add(e);
    }
    final appStoreSlotsByLocale = <String, Set<String>>{};
    for (final MapEntry(key: (code, slotId), value: g) in groups.entries) {
      final first = g.first;
      final slot = first.item.slot;
      logger.info('[${first.item.device} ${first.item.locale}] $slot: ${g.length} -> '
          '${p.relative(p.dirname(first.path))}');
      if (slot.id == PlayClass.phone.id && g.length < 2) {
        logger.warn('${slot.store.label} "$code": ${g.length} phone screenshot; Play needs at '
            'least 2 to publish.');
      }
      if (slot.store == Store.appStore) {
        appStoreSlotsByLocale.putIfAbsent(code, () => {}).add(slotId);
      }
    }
    appStoreSlotsByLocale.forEach((code, ids) {
      final iphones = ids.where((id) => !isIpadSlot(id));
      if (iphones.isNotEmpty && !iphones.any(appStoreRequiredIphone.contains)) {
        logger.warn('App Store "$code": no 6.9" or 6.5" iPhone screenshots. App Store Connect '
            'requires one of them; capture on e.g. an iPhone 17 Pro Max simulator.');
      }
      if (ids.any(isIpadSlot) && !ids.contains(appStoreRequiredIpad)) {
        logger.warn('App Store "$code": no 13" iPad screenshots, which App Store Connect requires '
            'for iPad apps.');
      }
    });
  }
}
