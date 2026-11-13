// app_store:, promotional_text, .env, feature_graphic: config, metadata,
// frame job, export and doctor.
import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/config.dart';
import 'package:brandify/src/doctor.dart';
import 'package:brandify/src/export/fastlane_exporter.dart';
import 'package:brandify/src/export/ownership.dart';
import 'package:brandify/src/frame/frame_job.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/metadata/metadata_writer.dart';
import 'package:brandify/src/png.dart';
import 'package:brandify/src/process.dart';
import 'package:brandify/src/store/slots.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

class _Sink implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

Matcher fails(String fragment) =>
    throwsA(isA<BrandifyException>().having((e) => e.message, 'message', contains(fragment)));

const _metadata = '''
metadata:
  en-US:
    name: Acme Tasks
    subtitle: Plan your day
    description: Everything in one place.
''';

const _appStore = r'''
app_store:
  primary_category: Photo & Video
  secondary_category: productivity
  copyright: 2026 Acme Inc.
  support_url: https://acme.example/support
  privacy_url: https://acme.example/privacy
  review:
    first_name: Ada
    last_name: Lovelace
    email: ada@acme.example
    phone: +1 555 0100
    demo_password: ${DEMO_PASSWORD}
    notes: Tap Settings to reach the paid feature.
''';

void main() {
  late Directory root;
  late _Sink out;
  late Logger logger;

  void write(String rel, String content) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  setUp(() {
    root = Directory.systemTemp.createTempSync('bf_extras');
    out = _Sink();
    logger = Logger(out: out, err: out);
    write('pubspec.yaml', 'name: acme\nversion: 1.0.0+3\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();
  bool exists(String rel) => File(p.join(root.path, rel)).existsSync();

  BrandifyConfig config(String extra,
          {String locales = '[en-US]', String devices = '[{id: p, platform: android, avd: a}]'}) =>
      BrandifyConfig.parse('locales: $locales\ndevices: $devices\n$extra', root: root.path);

  group('config', () {
    test('app_store: categories by any spelling, URLs checked, review fields', () {
      final a = config(_appStore).appStore!;
      expect(a.primaryCategory, 'PHOTO_AND_VIDEO');
      expect(a.secondaryCategory, 'PRODUCTIVITY');
      expect(a.review['phone'], '+1 555 0100');
      expect(a.review['demo_password'], r'${DEMO_PASSWORD}', reason: 'expanded when written, not parsed');
      expect(a.values.keys, containsAll(['copyright', 'review.notes']));

      expect(() => config('app_store: {primary_category: games and stuff}'), fails('Unknown App Store category'));
      expect(() => config('app_store: {primary_category: utilities, secondary_category: UTILITIES}'),
          fails('same as primary_category'));
      expect(() => config('app_store: {support_url: acme.example}'), fails('full URL'));
      expect(config(r'app_store: {support_url: "${SUPPORT}"}').appStore!.supportUrl, r'${SUPPORT}');
      expect(() => config('app_store: {review: {mail: x}}'), fails('Unknown key `mail`'));
      expect(config('app_store:\n  primary_category:\n  review:\n    email:\n').appStore!.values, isEmpty,
          reason: 'the init template, unfilled');
    });

    test('promotional_text is a metadata field', () {
      expect(config('metadata: {en-US: {promotional_text: New!}}').metadata['en-US']!.promotionalText, 'New!');
    });

    test('feature_graphic: present (even empty) turns it on; text falls back to metadata', () {
      expect(config('').featureGraphic, isNull);
      expect(config('feature_graphic:').featureGraphic, isNotNull);
      final c = config('$_metadata'
          'feature_graphic: {background: "#000000", text_color: "#FF0000", logo: none}\n');
      expect(c.featureGraphic!.background, [0xFF000000]);
      expect(c.featureGraphic!.textColor, 0xFFFF0000);
      expect(c.featureGraphicLogo, isNull);
      expect(c.featureGraphicText('en-US')!.toJson(), {'headline': 'Acme Tasks', 'subheadline': 'Plan your day'});

      final own = config('$_metadata'
          'feature_graphic: {text: {en-US: Just this}}\napp: {logo_path: logo.png}\n');
      expect(own.featureGraphicText('en-US')!.toJson(), {'headline': 'Just this'});
      expect(own.featureGraphicLogo, p.join(root.path, 'logo.png'));
      expect(() => config('feature_graphic: {text: {fr-FR: Salut}}'), fails('not in `locales`'));
    });

    test('.env: NAME=value lines, the environment wins', () {
      write('.env', '# secrets\nexport A=1\nB = "two words"\nC=\'x # y\'\nD=plain # note\n\n');
      expect(parseDotEnv(File(p.join(root.path, '.env'))),
          {'A': '1', 'B': 'two words', 'C': 'x # y', 'D': 'plain'});
      expect(brandifyEnv(root.path, {'A': 'env'}), {'A': 'env', 'B': 'two words', 'C': 'x # y', 'D': 'plain'});
      write('.env', 'not a line\n');
      expect(() => parseDotEnv(File(p.join(root.path, '.env'))), throwsA(isA<ConfigException>()));

      final unset = <String>[];
      expect(expandEnv(r'a ${X} b ${Y}', {'X': '1'}, unset), r'a 1 b ${Y}');
      expect(unset, ['Y']);
      expect(envRefs(r'${A}${B_2} $C'), ['A', 'B_2']);
    });
  });

  group('metadata', () {
    MetadataWriter writer(BrandifyConfig c, [Map<String, String> env = const {'DEMO_PASSWORD': 's3cret'}]) =>
        MetadataWriter(config: c, logger: logger, env: env);

    test('writes app_store files for deliver, once, and the URLs into every locale', () {
      final c = config('$_metadata  de-DE: {name: Acme, description: Alles.}\n$_appStore',
          locales: '[en-US, de-DE]');
      writer(c).run(stores: {Store.appStore});
      const m = 'fastlane/metadata';
      expect(read('$m/primary_category.txt'), 'PHOTO_AND_VIDEO');
      expect(read('$m/secondary_category.txt'), 'PRODUCTIVITY');
      expect(read('$m/copyright.txt'), '2026 Acme Inc.');
      expect(read('$m/en-US/privacy_url.txt'), 'https://acme.example/privacy');
      expect(read('$m/de-DE/support_url.txt'), 'https://acme.example/support');
      expect(exists('$m/en-US/marketing_url.txt'), isFalse);
      expect(read('$m/review_information/email_address.txt'), 'ada@acme.example');
      expect(read('$m/review_information/phone_number.txt'), '+1 555 0100');
      expect(read('$m/review_information/demo_password.txt'), 's3cret');
      expect(exists('$m/review_information/demo_user.txt'), isFalse);
      expect(exists('fastlane/metadata/android/en-US/privacy_url.txt'), isFalse, reason: 'App Store only');
      final record = jsonDecode(read('fastlane/${OwnershipRecord.fileName}'))['files'] as Map;
      expect(record.keys, contains('metadata/review_information/notes.txt'));
      expect(out.lines, contains(contains('App Store app_store: 9 files')));
    });

    test('an unset \${NAME} stops the run before anything is written', () {
      final c = config('$_metadata$_appStore');
      expect(() => writer(c, const {}).run(), fails(r'`app_store.review.demo_password` uses ${DEMO_PASSWORD}'));
      expect(exists('fastlane/metadata/en-US/name.txt'), isFalse);
    });

    test('a field emptied later is deleted; -l leaves the shared files alone', () {
      writer(config('$_metadata$_appStore')).run();
      expect(exists('fastlane/metadata/copyright.txt'), isTrue);
      writer(config(_metadata)).run(locales: {'en-US'});
      expect(exists('fastlane/metadata/copyright.txt'), isTrue, reason: '-l run');
      expect(exists('fastlane/metadata/en-US/privacy_url.txt'), isFalse, reason: 'per-locale, emptied');
      writer(config(_metadata)).run();
      expect(exists('fastlane/metadata/copyright.txt'), isFalse);
      expect(exists('fastlane/metadata/review_information/notes.txt'), isFalse);
    });

    test('promotional_text: written for the App Store, limit checked', () {
      writer(config('metadata: {en-US: {name: A, subtitle: S, description: D, promotional_text: New!}}')).run();
      expect(read('fastlane/metadata/en-US/promotional_text.txt'), 'New!');
      expect(() => writer(config('metadata: {en-US: {name: A, description: D, promotional_text: ${'x' * 171}}}'))
          .run(stores: {Store.appStore}), fails('at most 170'));
    });

    test('appStoreGaps: what App Store Connect needs before a submission', () {
      expect(appStoreGaps(config(_appStore).appStore), isEmpty);
      expect(appStoreGaps(null), hasLength(8));
      expect(appStoreGaps(config('app_store: {copyright: x}').appStore),
          allOf(contains('app_store.privacy_url'), contains('app_store.review.phone'), isNot(contains('app_store.copyright'))));
    });
  });

  group('feature graphic', () {
    const devices = '[{id: pixel, platform: android, avd: a}, {id: iphone, platform: ios, simulator: X}]';

    void png(String rel, int w, int h, {bool alpha = false}) => File(p.join(root.path, rel))
      ..createSync(recursive: true)
      ..writeAsBytesSync(img.encodePng(img.Image(width: w, height: h, numChannels: alpha ? 4 : 3)
        ..clear(img.ColorRgba8(10, 20, 30, 255))));

    test('the frame job carries it, even with no captures; Play-skipped locales left out', () {
      png('logo.png', 1024, 1024);
      final c = config('$_metadata  de-DE: {name: Acme DE}\napp: {logo_path: logo.png}\n'
          'frame: {background: ["#000000", "#FFFFFF"]}\nfeature_graphic: {}\n'
          'export: {locales: {de-DE: {play: none}}}\n',
          locales: '[en-US, de-DE]', devices: devices);
      final job = FrameJob.build(c, logger: logger);
      expect(job.items, isEmpty);
      expect(job.featureGraphics.map((f) => f.locale), ['en-US']);
      expect(job.featureGraphics.single.out, p.join(root.path, 'build/brandify/framed/_feature_graphic/en-US.png'));
      final json = jsonDecode(job.encode()) as Map<String, Object?>;
      expect(json['brandify_frame_job'], 2);
      final fg = json['feature_graphic'] as Map<String, Object?>;
      expect(fg['style'], {
        'background': [0xFF000000, 0xFFFFFFFF],
        'text_color': 0xFF111111, // mid grey on average: black reads better
        'logo': p.join(root.path, 'logo.png'),
      });
      expect((fg['items'] as List).single, containsPair('text', {'headline': 'Acme Tasks', 'subheadline': 'Plan your day'}));

      expect(() => FrameJob.build(c, devices: {'iphone'}, logger: logger), fails('No capture for iphone'),
          reason: 'no Android device selected: no feature graphic, so the capture is needed');
    });

    test('missing text or logo is an error naming the fix', () {
      expect(() => FrameJob.build(config('feature_graphic: {}', devices: devices), logger: logger),
          fails('no text for en-US. Fill in metadata.en-US.name'));
      expect(() => FrameJob.build(config('${_metadata}app: {logo_path: gone.png}\nfeature_graphic: {}', devices: devices),
          logger: logger), fails('app.logo_path: gone.png does not exist'));
    });

    test('readable text colour', () {
      expect(FrameJob.readableOn([0xFF0E2E28, 0xFF2E7D6B]), 0xFFFFFFFF);
      expect(FrameJob.readableOn([0xFFF2F2F7]), 0xFF111111);
    });

    test('export: featureGraphic.png per Play locale, opaque; foreign ones stop it', () {
      final c = config('${_metadata}feature_graphic: {logo: none}\n', devices: devices);
      png('build/brandify/framed/_feature_graphic/en-US.png', 1024, 500, alpha: true);
      final dest = 'fastlane/metadata/android/en-US/images/featureGraphic.png';

      write('fastlane/metadata/android/en-US/images/featureGraphic.jpg', 'theirs');
      expect(() => FastlaneExporter(config: c, logger: logger).run(), fails('featureGraphic.jpg'));
      expect(exists(dest), isFalse);

      FastlaneExporter(config: c, logger: logger).run(replace: true);
      expect(exists('fastlane/metadata/android/en-US/images/featureGraphic.jpg'), isFalse);
      final bytes = File(p.join(root.path, dest)).readAsBytesSync();
      expect(pngSize(bytes), (width: 1024, height: 500));
      expect(pngHasAlpha(bytes), isFalse);
      expect(out.lines, contains(contains('Google Play feature graphic ->')));

      // brandify's own file is replaced without --replace.
      png('build/brandify/framed/_feature_graphic/en-US.png', 1024, 500);
      FastlaneExporter(config: c, logger: logger).run();

      png('build/brandify/framed/_feature_graphic/en-US.png', 1000, 500);
      expect(() => FastlaneExporter(config: c, logger: logger).run(), fails('Run `brandify frame` again'));
    });
  });

  group('doctor', () {
    Handler tools({Set<String> ignored = const {}, bool git = true}) => (exe, args) {
          final cmd = [p.basename(exe), ...args].join(' ');
          if (cmd == 'flutter --version --machine') return ok('{"frameworkVersion": "3.38.1"}');
          if (cmd == 'adb version') return ok('Android Debug Bridge version 1.0.41\n');
          if (cmd == 'emulator -list-avds') return ok('a\n');
          if (cmd == 'fastlane --version') throw BrandifyException('no fastlane');
          if (cmd.startsWith('git ')) {
            if (!git) throw BrandifyException('no git');
            return ignored.contains(p.relative(args.last, from: root.path)) ? ok() : CommandResult(1, const [], '');
          }
          return null;
        };

    Future<List<Check>> doctor(String extra, {Handler? h, Map<String, String> env = const {}}) {
      write('brandify.yaml', 'locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\n$extra');
      write('pubspec.yaml', 'name: acme\ndev_dependencies:\n  brandify_flutter: any\n');
      write('integration_test/brandify_test.dart', '');
      return Doctor(configPath: p.join(root.path, 'brandify.yaml'), runner: FakeRunner([h ?? tools()]),
              isMacOS: false, env: {'ANDROID_HOME': '/nonexistent', ...env})
          .run();
    }

    Check named(List<Check> cs, String prefix) => cs.singleWhere((c) => c.title.startsWith(prefix));

    test('app_store: not set, gaps, unset \${NAME}, ready', () async {
      expect(named(await doctor(''), 'app_store').status, CheckStatus.skip);

      final gaps = named(await doctor('app_store: {primary_category: utilities}'), 'app_store');
      expect(gaps.status, CheckStatus.warn);
      expect(gaps.title, contains('7 fields App Store Connect needs'));
      expect(gaps.hint, allOf(contains('app_store.copyright'), contains('app_store.review.email')));

      final unset = named(await doctor('$_metadata$_appStore', h: tools(ignored: {'.env', 'fastlane/metadata/review_information/demo_password.txt'})), 'app_store');
      expect(unset.status, CheckStatus.warn);
      expect(unset.hint, allOf(contains(r'${DEMO_PASSWORD}'), contains('.env next to brandify.yaml')));

      write('.env', 'DEMO_PASSWORD=s3cret\n');
      final cs = await doctor('$_metadata$_appStore');
      expect(named(cs, 'app_store'), isA<Check>().having((c) => c.status, 'status', CheckStatus.ok));
      expect(named(cs, 'app_store').title, 'app_store: photo_and_video, review contact Ada Lovelace');
    });

    test('secrets: .env and files written from \${NAME} must be git-ignored', () async {
      write('.env', 'DEMO_PASSWORD=s3cret\n');
      var s = named(await doctor('$_metadata$_appStore'), 'Secrets');
      expect(s.status, CheckStatus.warn);
      expect(s.hint, allOf(contains('  .env'), contains('fastlane/metadata/review_information/demo_password.txt')));

      s = named(await doctor('$_metadata$_appStore', h: tools(ignored: {'.env', 'fastlane/metadata/review_information/demo_password.txt'})), 'Secrets');
      expect(s.status, CheckStatus.ok);

      final noGit = await doctor('$_metadata$_appStore', h: tools(git: false));
      expect(noGit.any((c) => c.title.startsWith('Secrets')), isFalse);

      File(p.join(root.path, '.env')).deleteSync();
      final plain = await doctor('${_metadata}app_store: {copyright: x}');
      expect(plain.any((c) => c.title.startsWith('Secrets')), isFalse, reason: 'nothing secret');
    });

    test('feature_graphic: not set, can\'t be made, ready', () async {
      final none = named(await doctor(''), 'feature_graphic');
      expect(none.status, CheckStatus.skip);
      expect(none.hint, contains('feature_graphic: {}'));

      final noText = named(await doctor('feature_graphic: {}'), 'feature_graphic');
      expect(noText.status, CheckStatus.warn);
      expect(noText.hint, contains('metadata.en-US.name'));

      final ready = named(await doctor('${_metadata}feature_graphic: {logo: none}'), 'feature_graphic');
      expect((ready.status, ready.title), (CheckStatus.ok, 'feature_graphic: en-US "Acme Tasks", text only'));
    });
  });
}
