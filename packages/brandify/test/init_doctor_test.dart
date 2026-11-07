import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/commands/doctor_command.dart';
import 'package:brandify/src/config.dart';
import 'package:brandify/src/doctor.dart';
import 'package:brandify/src/init.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/process.dart';
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

const _pubspec = '''
name: acme
dependencies:
  flutter: {sdk: flutter}
dev_dependencies:
  flutter_test: {sdk: flutter}
''';

String _simctl(List<(String name, String runtime)> sims) => jsonEncode({
      'devices': {
        for (final (_, rt) in sims)
          'com.apple.CoreSimulator.SimRuntime.$rt': [
            for (final (n, r) in sims)
              if (r == rt) {'udid': 'U-$n-$r', 'name': n, 'state': 'Shutdown', 'isAvailable': true}
          ]
      }
    });

void main() {
  late Directory root;
  late _Sink out, err;
  late Logger logger;
  final env = {'ANDROID_HOME': '/nonexistent'};

  setUp(() {
    root = Directory.systemTemp.createTempSync('bf_init');
    out = _Sink();
    err = _Sink();
    logger = Logger(out: out, err: err);
  });
  tearDown(() => root.deleteSync(recursive: true));

  void write(String rel, String content) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();

  group('init', () {
    Initializer init(FakeRunner r) => Initializer(root: root.path, runner: r, logger: logger, env: env);

    test('writes a valid config and a test that starts the app', () async {
      write('pubspec.yaml', _pubspec);
      write('lib/main.dart', 'void main() {}');
      final r = FakeRunner([(exe, args) => args.contains('-list-avds') ? ok('INFO    | x\nPixel_9\nSmall\n') : null]);
      await init(r).run();

      final c = BrandifyConfig.parse(read('brandify.yaml'), root: root.path);
      expect((c.devices.first as AndroidDeviceConfig).avd, 'Pixel_9');
      expect((c.devices.last as IosDeviceConfig).simulator, 'iPhone 17 Pro Max');
      expect(c.frame.captions['en-US']!.keys, ['home']);
      final t = read('integration_test/brandify_test.dart');
      expect(t, contains("import 'package:acme/main.dart' as app;"));
      expect(t, contains('app.main();'));
      expect(t, contains("await shot('home');"));
      expect(out.lines, contains(contains('flutter pub add dev:brandify_flutter dev:brandify')));
      expect(out.lines, contains(contains('also found: Small')));
    });

    test('no AVD and no lib/main.dart: placeholders, still a valid config', () async {
      write('pubspec.yaml', _pubspec);
      await init(FakeRunner([(_, __) => throw BrandifyException('Could not run')])).run();
      final yaml = read('brandify.yaml');
      expect(yaml, contains('avd: $placeholderAvd   # TODO'));
      BrandifyConfig.parse(yaml, root: root.path);
      expect(read('integration_test/brandify_test.dart'), allOf(contains('TODO: start your app'), isNot(contains('app.main'))));
      expect(err.lines, contains(contains('no Android AVD found')));
    });

    test('refuses to overwrite without --force, and non-Flutter folders', () async {
      await expectLater(init(FakeRunner()).run(), throwsA(isA<BrandifyException>()));
      write('pubspec.yaml', 'name: tool\ndependencies: {path: any}\n');
      await expectLater(
          init(FakeRunner()).run(),
          throwsA(isA<BrandifyException>().having((e) => e.message, 'm', contains('not a Flutter app'))));
      write('pubspec.yaml', _pubspec);
      write('brandify.yaml', 'mine');
      await expectLater(
          init(FakeRunner()).run(),
          throwsA(isA<BrandifyException>().having((e) => e.message, 'm', contains('brandify.yaml exists'))));
      expect(read('brandify.yaml'), 'mine');
      expect(File(p.join(root.path, 'integration_test/brandify_test.dart')).existsSync(), isFalse);
      await init(FakeRunner()).run(force: true);
      expect(read('brandify.yaml'), contains('locales: [en-US]'));
    });
  });

  group('doctor', () {
    const flutterOk = '{"frameworkVersion": "3.38.1", "dartSdkVersion": "3.10.0 (build 3.10.0)"}';

    Handler tools({
      String flutter = flutterOk,
      String avds = 'Pixel_9\n',
      String adbDevices = 'List of devices attached\nemulator-5554\tdevice\n',
      String? simctl,
      bool xcode = true,
      bool adb = true,
      bool fastlane = false,
    }) =>
        (exe, args) {
          final cmd = [p.basename(exe), ...args].join(' ');
          if (cmd == 'flutter --version --machine') return ok('Waiting...\n$flutter');
          if (cmd == 'adb version') {
            if (!adb) throw BrandifyException('Could not run `adb`');
            return ok('Android Debug Bridge version 1.0.41\n');
          }
          if (cmd == 'adb devices') return ok(adbDevices);
          if (cmd == 'emulator -list-avds') return ok(avds);
          if (cmd == 'xcodebuild -version') return xcode ? ok('Xcode 27.0\nBuild version 27A1\n') : failed();
          if (cmd.startsWith('xcrun simctl list')) {
            return ok(simctl ?? _simctl([('iPhone 17 Pro Max', 'iOS-26-4')]));
          }
          if (cmd == 'fastlane --version') {
            if (!fastlane) throw BrandifyException('Could not run `fastlane`');
            return ok('fastlane installation at path: x\n-----\nfastlane 2.228.0\n');
          }
          return failed('unexpected $cmd');
        };

    Future<List<Check>> doctor(Handler h, {bool mac = true, Set<String> devices = const {}}) =>
        Doctor(configPath: p.join(root.path, 'brandify.yaml'), runner: FakeRunner([h]), isMacOS: mac, env: env,
                devices: devices)
            .run();

    void project({String devices = '[{id: pixel, platform: android, avd: Pixel_9}, '
        '{id: iphone69, platform: ios, simulator: iPhone 17 Pro Max}]'}) {
      write('pubspec.yaml', '$_pubspec  brandify_flutter: {path: x}\n');
      write('brandify.yaml', 'locales: [en-US, de-DE]\ndevices: $devices\n');
      write('integration_test/brandify_test.dart', '');
    }

    String show(List<Check> cs) => cs.map((c) => '${c.status.mark} ${c.title} ${c.hint ?? ''}').join('\n');

    test('all good', () async {
      project();
      final cs = await doctor(tools(fastlane: true));
      expect(cs.map((c) => c.status).toSet(), {CheckStatus.ok}, reason: show(cs));
      expect(show(cs), allOf(contains('Flutter 3.38.1 (Dart 3.10.0)'), contains('[pixel] AVD Pixel_9'),
          contains('[iphone69] iPhone 17 Pro Max (iOS 26.4)'), contains('Xcode 27.0'), contains('fastlane 2.228.0'),
          contains('2 locales (en-US, de-DE), 2 devices')));
      expect(printChecks(cs, logger), 0);
      expect(out.lines.last, 'Ready to capture.');
    });

    test('reports each problem with what to do', () async {
      project();
      final cs = await doctor(tools(
          flutter: '{"frameworkVersion": "3.32.0"}',
          avds: 'Other_AVD\n',
          simctl: _simctl([('iPhone 16', 'iOS-18-0')])));
      final failures = cs.where((c) => c.status == CheckStatus.fail).map((c) => c.title).toList();
      expect(failures, [
        'Flutter 3.32.0',
        '[pixel] no AVD named "Pixel_9"',
        '[iphone69] simulator not found',
      ], reason: show(cs));
      expect(show(cs), allOf(contains('Available: Other_AVD.'), contains('Available: iPhone 16.'),
          contains('fastlane not found (optional)')));
      expect(printChecks(cs, logger), 1);
      expect(out.lines.last, '3 problems to fix before capturing.');
    });

    test('iOS devices on Linux are a warning, not a failure', () async {
      project();
      final cs = await doctor(tools(), mac: false);
      final ios = cs.singleWhere((c) => c.title.startsWith('iOS'));
      expect(ios.status, CheckStatus.warn);
      expect(ios.hint, contains('capture skips iphone69'));
      expect(printChecks(cs, logger), 0);
    });

    test('no adb on a Mac: Android devices are a warning, unless asked for with -d', () async {
      project();
      var cs = await doctor(tools(adb: false));
      final adb = cs.singleWhere((c) => c.title.startsWith('Android'));
      expect(adb.status, CheckStatus.warn, reason: show(cs));
      expect(adb.hint, contains('capture skips pixel'));
      expect(printChecks(cs, logger), 0);

      cs = await doctor(tools(adb: false), devices: {'pixel'});
      expect(cs.singleWhere((c) => c.title.startsWith('Android')).status, CheckStatus.fail);
      expect(cs.any((c) => c.title.startsWith('iOS')), isFalse, reason: 'iphone69 not selected');

      cs = await doctor(tools(), devices: {'iphone69'}, mac: false);
      expect(cs.singleWhere((c) => c.title.startsWith('iOS')).status, CheckStatus.fail);

      cs = await doctor(tools(), devices: {'tablet'});
      expect(show(cs), contains('Unknown device tablet'));
    });

    test('fails when every configured device would be skipped', () async {
      project(devices: '[{id: pixel, platform: android, avd: Pixel_9}]');
      final cs = await doctor(tools(adb: false));
      expect(cs.singleWhere((c) => c.title.startsWith('No configured device')).status, CheckStatus.fail);
      expect(printChecks(cs, logger), 1);
    });

    test('no config: says to run init, checks both platforms; offline serial is a warning', () async {
      write('pubspec.yaml', _pubspec);
      var cs = await doctor(tools(xcode: false));
      expect(show(cs), allOf(contains('does not depend on brandify_flutter'), contains('brandify init'),
          contains('Android: AVDs Pixel_9'), contains('iOS: Xcode not found')));
      expect(cs.singleWhere((c) => c.title.contains('Xcode')).status, CheckStatus.warn);

      project(devices: '[{id: phone, platform: android, serial: R5CT}]');
      cs = await doctor(tools());
      expect(cs.singleWhere((c) => c.title.contains('R5CT')).status, CheckStatus.warn);
      expect(cs.any((c) => c.title.startsWith('iOS')), isFalse, reason: 'no iOS device configured');
    });

    test('version and tool output parsing', () {
      expect(compareVersions('3.35.3', minFlutter), 0);
      expect(compareVersions('3.38.0-0.1.pre', minFlutter), greaterThan(0));
      expect(compareVersions('3.35', minFlutter), lessThan(0));
      expect(compareVersions('4.0.0', minFlutter), greaterThan(0));
      expect(parseAdbDevices('List of devices attached\nemulator-5554\tdevice\nR5CT\toffline\n\n'), {'emulator-5554'});
    });
  });
}
