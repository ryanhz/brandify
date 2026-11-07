import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/config.dart';
import 'package:brandify/src/export/fastlane_exporter.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/png.dart';
import 'package:brandify/src/process.dart';
import 'package:brandify/src/store/locales.dart';
import 'package:brandify/src/store/slots.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Sink implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

Matcher throwsBp(String fragment) =>
    throwsA(isA<BrandifyException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  group('locale mapping', () {
    String play(String t) => storeLocale(Store.play, t);
    String app(String t) => storeLocale(Store.appStore, t);

    test('exact codes pass through', () {
      expect(play('en-US'), 'en-US');
      expect(app('en-US'), 'en-US');
      expect(play('de-DE'), 'de-DE');
      expect(app('zh-Hans'), 'zh-Hans');
      expect(play('es-419'), 'es-419');
    });
    test('Chinese by script or region', () {
      expect(play('zh-Hans'), 'zh-CN');
      expect(play('zh-Hant'), 'zh-TW');
      expect(play('zh-HK'), 'zh-HK');
      expect(play('zh-Hans-CN'), 'zh-CN');
      expect(app('zh-CN'), 'zh-Hans');
      expect(app('zh-TW'), 'zh-Hant');
      expect(app('zh-Hant-HK'), 'zh-Hant');
      expect(() => play('zh'), throwsBp('zh-CN, zh-HK, zh-TW'));
    });
    test('store aliases', () {
      expect(play('he'), 'iw-IL');
      expect(play('he-IL'), 'iw-IL');
      expect(app('he-IL'), 'he');
      expect(play('nb-NO'), 'no-NO');
      expect(app('nb'), 'no');
      expect(play('es-MX'), 'es-419');
      expect(app('es-MX'), 'es-MX');
      expect(play('tl'), 'fil');
    });
    test('regional tag to the store\'s language-only code, and back', () {
      expect(app('ja-JP'), 'ja');
      expect(app('it-IT'), 'it');
      expect(app('ko-KR'), 'ko');
      expect(play('ja'), 'ja-JP');
      expect(play('de'), 'de-DE');
      expect(app('de'), 'de-DE');
      expect(play('sk-SK'), 'sk');
    });
    test('no guessing: ambiguous or missing is an error naming the fix', () {
      expect(() => play('en'), throwsBp('closest: en-AU'));
      expect(() => play('de-AT'), throwsBp('export: {locales: {de-AT: {play: <code>}}}'));
      expect(() => app('ur-IN'), throwsBp('closest: ur-PK'));
      expect(() => play('ur-PK'), throwsBp('`play: none`'));
    });
  });

  group('store rules', () {
    final phone = slotFor(DevicePlatform.android, 1080, 2400);
    final iphone = slotFor(DevicePlatform.ios, 1320, 2868);
    List<String> check(StoreSlot s, int w, int h, {bool alpha = false, int bytes = 1000}) =>
        storeRuleViolations(s, width: w, height: h, hasAlpha: alpha, bytes: bytes);

    test('a correct image passes', () {
      expect(check(phone, 1080, 1920), isEmpty);
      expect(check(iphone, 1320, 2868), isEmpty);
    });
    test('size, alpha, Play limits', () {
      expect(check(phone, 1080, 2400), contains(contains('needs 1080×1920')));
      expect(check(phone, 1080, 2400), contains(contains('twice its width')));
      expect(check(phone, 1080, 1920, alpha: true), [contains('alpha channel')]);
      expect(check(phone, 1080, 1920, bytes: 9 * 1024 * 1024), [contains('over Play\'s 8 MB')]);
      expect(check(iphone, 1290, 2796), contains(contains('needs 1320×2868')));
    });
  });

  group('png', () {
    test('alpha detection and flattening', () {
      final rgb = img.encodePng(img.Image(width: 4, height: 4));
      final opaque = img
          .encodePng(img.Image(width: 4, height: 4, numChannels: 4)..clear(img.ColorRgba8(10, 20, 30, 255)));
      final clear = img.encodePng(img.Image(width: 4, height: 4, numChannels: 4));
      expect(pngHasAlpha(rgb), isFalse);
      expect(pngHasAlpha(opaque), isTrue);
      final flat = flattenOpaquePng(opaque)!;
      expect(pngHasAlpha(flat), isFalse);
      expect(img.decodePng(flat)!.getPixel(1, 1).r, 10);
      expect(flattenOpaquePng(clear), isNull);
    });
  });

  group('export config', () {
    BrandifyConfig parse(String export) => BrandifyConfig.parse('''
locales: [en-US, de-AT, ur-PK]
devices: [{id: pixel, platform: android, avd: a}]
$export
''', root: '/proj');

    test('defaults', () {
      final c = parse('');
      expect(c.export.output, 'fastlane');
      expect(c.fastlaneDir, '/proj/fastlane');
    });
    test('overrides, with none', () {
      final c = parse(
          'export: {output: out/fl, locales: {de-AT: {play: de-DE, app_store: de-DE}, ur-PK: {play: none}}}');
      expect(c.fastlaneDir, '/proj/out/fl');
      expect(c.export.locales['de-AT'], {Store.play: 'de-DE', Store.appStore: 'de-DE'});
      expect(c.export.locales['ur-PK'], {Store.play: null});
    });
    test('rejects unknown codes and locales', () {
      expect(
          () => parse('export: {locales: {de-AT: {play: de-AT}}}'),
          throwsA(isA<ConfigException>()
              .having((e) => e.message, 'm', contains('not a Google Play listing language'))));
      expect(() => parse('export: {locales: {fr-FR: {play: fr-FR}}}'),
          throwsA(isA<ConfigException>().having((e) => e.message, 'm', contains('not in `locales`'))));
      expect(() => parse('export: {locales: {de-AT: {google: de-DE}}}'),
          throwsA(isA<ConfigException>().having((e) => e.message, 'm', contains('Unknown key'))));
    });
  });

  group('fastlane exporter', () {
    late Directory root;
    late _Sink out, err;
    late Logger logger;

    BrandifyConfig config({String locales = '[en-US, zh-Hans]', String extra = '', String devices = ''}) =>
        BrandifyConfig.parse('''
locales: $locales
devices:
  - {id: pixel, platform: android, avd: a}
  - {id: iphone, platform: ios, simulator: "iPhone 17 Pro Max"}
$devices
$extra
''', root: root.path);

    /// A raw capture plus its framed images at [fw]×[fh] (what `frame` writes).
    void captured(String device, String locale, List<String> shots,
        {required int w,
        required int h,
        required int fw,
        required int fh,
        double dpr = 3,
        int channels = 3}) {
      final raw = Directory(p.join(root.path, 'build/brandify/raw', device, locale))
        ..createSync(recursive: true);
      final framed = Directory(p.join(root.path, 'build/brandify/framed', device, locale))
        ..createSync(recursive: true);
      for (final s in shots) {
        File(p.join(raw.path, '$s.png')).writeAsBytesSync(img.encodePng(img.Image(width: w, height: h)));
        final f = img.Image(width: fw, height: fh, numChannels: channels)
          ..clear(img.ColorRgba8(40, 80, 200, 255));
        File(p.join(framed.path, '$s.png')).writeAsBytesSync(img.encodePng(f));
      }
      File(p.join(raw.path, 'manifest.json')).writeAsStringSync(jsonEncode({
        'brandify_manifest': 1,
        'view': {'dpr': dpr, 'width': w, 'height': h},
        'shots': [
          for (final s in shots) {'name': s, 'file': '$s.png', 'width': w, 'height': h}
        ],
      }));
    }

    void pixel(String locale, List<String> shots) =>
        captured('pixel', locale, shots, w: 1080, h: 2400, fw: 1080, fh: 1920, dpr: 2.625);
    void iphone(String locale, List<String> shots) =>
        captured('iphone', locale, shots, w: 1320, h: 2868, fw: 1320, fh: 2868);

    List<String> files(String rel) {
      final d = Directory(p.join(root.path, rel));
      if (!d.existsSync()) return [];
      return d.listSync().map((e) => p.basename(e.path)).toList()..sort();
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('bf_export');
      out = _Sink();
      err = _Sink();
      logger = Logger(out: out, err: err);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('writes supply and deliver folders, {n}_{name}.png in capture order, mapped locales', () {
      pixel('en-US', ['home', 'add_task', 'settings']);
      pixel('zh-Hans', ['home', 'add_task', 'settings']);
      iphone('en-US', ['home', 'add_task', 'settings']);
      iphone('zh-Hans', ['home', 'add_task', 'settings']);

      final written = FastlaneExporter(config: config(), logger: logger).run();
      expect(written, hasLength(12));
      const names = ['1_home.png', '2_add_task.png', '3_settings.png'];
      expect(files('fastlane/metadata/android/en-US/images/phoneScreenshots'), names);
      expect(files('fastlane/metadata/android/zh-CN/images/phoneScreenshots'), names);
      expect(files('fastlane/screenshots/en-US'), names);
      expect(files('fastlane/screenshots/zh-Hans'), names);
      for (final e in written) {
        final b = File(e.path).readAsBytesSync();
        expect(pngSize(b), (width: e.item.slot.width, height: e.item.slot.height));
      }
      expect(
          out.lines,
          contains(allOf(contains('Google Play phone (1080×1920): 3 -> '),
              contains('fastlane/metadata/android/zh-CN/images/phoneScreenshots'))));
      expect(err.lines, isEmpty);
    });

    test('pads n when a slot has 10, so names sort in order', () {
      final shots = [for (var i = 1; i <= 10; i++) 's$i'];
      iphone('en-US', shots);
      FastlaneExporter(config: config(locales: '[en-US]'), logger: logger).run(devices: {'iphone'});
      final f = files('fastlane/screenshots/en-US');
      expect(f.first, '01_s1.png');
      expect(f.last, '10_s10.png');
      expect(f, hasLength(10));
    });

    test('too many for the store is an error naming what would not upload', () {
      pixel('en-US', [for (var i = 1; i <= 9; i++) 's$i']);
      expect(() => FastlaneExporter(config: config(locales: '[en-US]'), logger: logger).run(),
          throwsBp('at most 8: s9 would not upload'));
      expect(files('fastlane/metadata/android/en-US/images/phoneScreenshots'), isEmpty,
          reason: 'nothing is touched when the plan fails');
    });

    test('replaces stale screenshots, keeps text metadata and other display classes', () {
      final phoneDir = p.join(root.path, 'fastlane/metadata/android/en-US/images/phoneScreenshots');
      Directory(phoneDir).createSync(recursive: true);
      File(p.join(phoneDir, '4_old.png')).writeAsBytesSync([1]);
      File(p.join(root.path, 'fastlane/metadata/android/en-US/title.txt')).writeAsStringSync('Acme');
      final asDir = p.join(root.path, 'fastlane/screenshots/en-US');
      Directory(asDir).createSync(recursive: true);
      File(p.join(asDir, '9_old_iphone.png'))
          .writeAsBytesSync(img.encodePng(img.Image(width: 1290, height: 2796)));
      File(p.join(asDir, 'ipad_1.png')).writeAsBytesSync(img.encodePng(img.Image(width: 2064, height: 2752)));

      pixel('en-US', ['home', 'add_task']);
      iphone('en-US', ['home', 'add_task']);
      FastlaneExporter(config: config(locales: '[en-US]'), logger: logger).run();

      expect(
          files('fastlane/metadata/android/en-US/images/phoneScreenshots'), ['1_home.png', '2_add_task.png']);
      expect(File(p.join(root.path, 'fastlane/metadata/android/en-US/title.txt')).existsSync(), isTrue);
      expect(files('fastlane/screenshots/en-US'), ['1_home.png', '2_add_task.png', 'ipad_1.png'],
          reason: 'the 6.9" set is replaced, the iPad set left alone');
    });

    test('flattens opaque RGBA to RGB; transparent pixels are an error', () {
      captured('pixel', 'en-US', ['home', 'b'],
          w: 1080, h: 2400, fw: 1080, fh: 1920, dpr: 2.625, channels: 4);
      final written = FastlaneExporter(config: config(locales: '[en-US]'), logger: logger).run();
      expect(written.every((e) => !pngHasAlpha(File(e.path).readAsBytesSync())), isTrue);

      final framed = File(p.join(root.path, 'build/brandify/framed/pixel/en-US/home.png'));
      framed.writeAsBytesSync(img.encodePng(img.Image(width: 1080, height: 1920, numChannels: 4)));
      expect(() => FastlaneExporter(config: config(locales: '[en-US]'), logger: logger).run(),
          throwsBp('transparent pixels'));
    });

    test('framed image missing, stale or off-size', () {
      pixel('en-US', ['home', 'b']);
      final framed = File(p.join(root.path, 'build/brandify/framed/pixel/en-US/home.png'));
      final raw = File(p.join(root.path, 'build/brandify/raw/pixel/en-US/home.png'));
      final c = config(locales: '[en-US]');

      raw.setLastModifiedSync(framed.lastModifiedSync().add(const Duration(minutes: 1)));
      expect(() => FastlaneExporter(config: c, logger: logger).run(), throwsBp('older than its capture'));

      framed.writeAsBytesSync(img.encodePng(img.Image(width: 1080, height: 2400)));
      raw.setLastModifiedSync(framed.lastModifiedSync().subtract(const Duration(minutes: 1)));
      expect(() => FastlaneExporter(config: c, logger: logger).run(), throwsBp('is 1080×2400'));

      framed.deleteSync();
      expect(() => FastlaneExporter(config: c, logger: logger).run(), throwsBp('Run `brandify frame` first'));
    });

    test('export.locales overrides and `none`; collisions are an error', () {
      pixel('de-AT', ['home', 'b']);
      iphone('de-AT', ['home']);
      final c =
          config(locales: '[de-AT]', extra: 'export: {locales: {de-AT: {play: de-DE, app_store: none}}}');
      final written = FastlaneExporter(config: c, logger: logger).run();
      expect(written.map((e) => e.storeLocale).toSet(), {'de-DE'});
      expect(files('fastlane/metadata/android/de-DE/images/phoneScreenshots'), hasLength(2));
      expect(files('fastlane/screenshots'), isEmpty);

      pixel('zh-CN', ['home', 'b']);
      pixel('zh-Hans', ['home', 'b']);
      expect(() => FastlaneExporter(config: config(locales: '[zh-CN, zh-Hans]'), logger: logger).run(),
          throwsBp('zh-CN and zh-Hans both map to Google Play "zh-CN"'));
    });

    test('several iOS display classes share a locale folder with device prefixes', () {
      iphone('en-US', ['home', 'b']);
      captured('ipad', 'en-US', ['home', 'b'], w: 2064, h: 2752, fw: 2064, fh: 2752);
      final c = config(
          locales: '[en-US]', devices: '  - {id: ipad, platform: ios, simulator: "iPad Pro 13-inch (M4)"}');
      FastlaneExporter(config: c, logger: logger).run(devices: {'iphone', 'ipad'});
      expect(files('fastlane/screenshots/en-US'),
          ['ipad_1_home.png', 'ipad_2_b.png', 'iphone_1_home.png', 'iphone_2_b.png']);
    });

    test('two devices in one slot is an error', () {
      pixel('en-US', ['home', 'b']);
      captured('pixel2', 'en-US', ['home', 'b'], w: 1080, h: 2400, fw: 1080, fh: 1920, dpr: 2.625);
      final c = config(locales: '[en-US]', devices: '  - {id: pixel2, platform: android, avd: b}');
      expect(() => FastlaneExporter(config: c, logger: logger).run(),
          throwsBp('Devices pixel and pixel2 both fill Google Play phone'));
    });

    test('Android tablet captures go to the tablet folders', () {
      captured('tab', 'en-US', ['home', 'b'], w: 1600, h: 2560, fw: 1600, fh: 2844, dpr: 2);
      final c = config(locales: '[en-US]', devices: '  - {id: tab, platform: android, avd: t}');
      FastlaneExporter(config: c, logger: logger).run(devices: {'tab'});
      expect(files('fastlane/metadata/android/en-US/images/tenInchScreenshots'), ['1_home.png', '2_b.png']);
    });

    test('warns about store minimums and required display classes', () {
      pixel('en-US', ['home']);
      captured('iphone', 'en-US', ['home'], w: 1206, h: 2622, fw: 1206, fh: 2622);
      FastlaneExporter(config: config(locales: '[en-US]'), logger: logger).run();
      expect(err.lines, contains(contains('Play needs at least 2')));
      expect(err.lines, contains(contains('no 6.9" or 6.5" iPhone screenshots')));
    });
  });
}
