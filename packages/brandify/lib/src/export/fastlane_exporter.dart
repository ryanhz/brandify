import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as img;
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
/// has 10), so both tools upload them in the order the test shot them. When
/// brandify.yaml has more than one iOS device, App Store names get a
/// `{device}_` prefix, since deliver keeps all display classes in one locale
/// folder. The prefix depends on the config, not on `-d`, so names stay the
/// same from run to run.
///
/// Everything is planned and checked before anything is touched. brandify
/// records what it wrote (path and SHA-256) in [manifestName] at the root of
/// the fastlane folder and only ever deletes or replaces files listed there
/// and unchanged since. Any other image that fastlane would upload alongside
/// brandify's set (any image in a supply slot folder; an image of a display
/// class being written, or a frameit `*_framed` image, in a deliver folder)
/// stops the export, unless `replace` is set, in which case it is deleted.
/// A file brandify would overwrite that isn't part of the set is always an
/// error. Text metadata is never touched. After writing, every file is read
/// back and checked against its store's rules.
class FastlaneExporter {
  FastlaneExporter({required this.config, required this.logger});

  final BrandifyConfig config;
  final Logger logger;

  /// Ownership record, relative to [BrandifyConfig.fastlaneDir]. Dotfiles are
  /// never matched by fastlane's globs.
  static const manifestName = '.brandify-export.json';

  String get _manifestPath => p.join(config.fastlaneDir, manifestName);

  List<ExportedImage> run({Set<String>? devices, Set<String>? locales, bool replace = false}) {
    final job = FrameJob.build(config, devices: devices, locales: locales, logger: logger);
    final plan = _plan(job.items);
    if (plan.isEmpty) {
      throw BrandifyException('Nothing to export: every captured locale is set to `none` in export.locales.');
    }
    final owned = _loadManifest();
    final stale = _survey(plan, owned, replace: replace);
    for (final f in stale) {
      File(f).deleteSync();
      owned.remove(_rel(f));
    }
    for (final dir in {for (final e in plan) p.dirname(e.path)}) {
      Directory(dir).createSync(recursive: true);
    }
    final written = <ExportedImage>[];
    for (final e in plan) {
      written.add(_write(e));
      owned[_rel(e.path)] = _sha(File(e.path).readAsBytesSync());
    }
    _saveManifest(owned);
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

    // From the config, not from this run's devices, so `export -d iphone`
    // and `export -d ipad` name files the same way as a full export.
    final prefixIos = config.devices.where((d) => d.platform == DevicePlatform.ios).length > 1;

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
      final prefix = slot.store == Store.appStore && prefixIos ? '${g.first.device}_' : '';
      if (slot.store == Store.appStore) {
        for (final i in g.where((i) => _framedName.hasMatch('_${i.shot}.png'))) {
          throw BrandifyException('[${i.device} ${i.locale}] shot "${i.shot}" would be exported as a '
              '`*_framed.png` file, which deliver takes for frameit output: it would then skip every '
              'other screenshot in "$code". Rename the shot.');
        }
      }
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

  /// frameit's output; deliver uploads only these when any exist in a folder.
  static final _framedName = RegExp(r'_framed\.(png|jpe?g)$', caseSensitive: false);

  /// What to delete before writing [plan]: images fastlane would upload with
  /// the new set. Throws, touching nothing, when one of them isn't
  /// brandify's (unless [replace]) or a target name is taken by a file
  /// outside the set.
  List<String> _survey(List<ExportedImage> plan, Map<String, String> owned, {required bool replace}) {
    final slotsByFolder = <String, Set<String>>{};
    for (final e in plan) {
      slotsByFolder.putIfAbsent(p.dirname(e.path), () => {}).add(e.item.slot.id);
    }
    // Lower-cased: APFS and NTFS are case-insensitive by default.
    final targets = {for (final e in plan) e.path.toLowerCase()};

    final stale = <String>[];
    final foreign = <String>[];
    final taken = <String>[];
    slotsByFolder.forEach((folder, slotIds) {
      final dir = Directory(folder);
      if (!dir.existsSync()) return;
      final deliver = p.isWithin(p.join(config.fastlaneDir, 'screenshots'), folder);
      final files = dir.listSync().whereType<File>().where((f) => _image.hasMatch(f.path)).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final f in files) {
        final bytes = f.readAsBytesSync();
        final ours = owned[_rel(f.path)] == _sha(bytes);
        final StoreSlot? cls;
        final String? why;
        if (!deliver) {
          // supply's slot folder: every image in it uploads with the set.
          cls = null;
          why = '';
        } else if (_framedName.hasMatch(f.path)) {
          cls = null;
          why = ' (frameit output: deliver would upload only `*_framed` files and skip brandify\'s)';
        } else {
          final size = _imageSize(bytes);
          cls = size == null ? null : appStoreSlotForSize(size.width, size.height);
          why = cls != null && slotIds.contains(cls.id) ? ' (${cls.label})' : null;
        }
        if (why != null) {
          if (ours || replace) {
            stale.add(f.path);
          } else {
            foreign.add('${p.relative(f.path)}$why');
          }
        } else if (targets.contains(f.path.toLowerCase())) {
          taken.add('${p.relative(f.path)} (${cls?.label ?? 'not an App Store screenshot size'})');
        }
      }
    });

    final problems = <String>[];
    if (foreign.isNotEmpty) {
      problems.add('These images would upload together with the new screenshots, but brandify did '
          'not write them (or they changed since):\n${foreign.map((l) => '  - $l').join('\n')}\n'
          'Move them out, or run `brandify export --replace` to delete them.');
    }
    if (taken.isNotEmpty) {
      problems.add('Exporting would overwrite files outside the set being written:\n'
          '${taken.map((l) => '  - $l').join('\n')}\nMove or delete them first.');
    }
    if (problems.isNotEmpty) throw BrandifyException(problems.join('\n'));

    final removed = <String, int>{};
    for (final f in stale) {
      removed.update(p.dirname(f), (n) => n + 1, ifAbsent: () => 1);
    }
    removed.forEach((dir, n) => logger.detail('removing $n old screenshots from ${p.relative(dir)}'));
    return stale;
  }

  static ({int width, int height})? _imageSize(Uint8List bytes) {
    final png = pngSize(bytes);
    if (png != null) return png;
    try {
      final info = img.JpegDecoder().startDecode(bytes);
      return info == null ? null : (width: info.width, height: info.height);
    } catch (_) {
      return null;
    }
  }

  static String _sha(List<int> bytes) => sha256.convert(bytes).toString();

  /// Manifest key: relative to the fastlane folder, always with `/`.
  String _rel(String path) => p.split(p.relative(path, from: config.fastlaneDir)).join('/');

  Map<String, String> _loadManifest() {
    final f = File(_manifestPath);
    if (!f.existsSync()) return {};
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return (j['files'] as Map<String, dynamic>).cast<String, String>();
    } catch (_) {
      throw BrandifyException('${p.relative(_manifestPath)} is not a brandify export record. '
          'Delete it; the next export then treats every existing screenshot as not brandify\'s.');
    }
  }

  void _saveManifest(Map<String, String> owned) {
    // Forget files that are gone (deleted by hand, or by a deliver download).
    owned.removeWhere((rel, _) => !File(p.join(config.fastlaneDir, rel)).existsSync());
    final sorted = {for (final k in owned.keys.toList()..sort()) k: owned[k]};
    File(_manifestPath).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
          'brandify_export': 1,
          'note': 'Screenshots written by `brandify export`. It only deletes or replaces files '
              'listed here and unchanged since.',
          'files': sorted,
        })}\n');
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
