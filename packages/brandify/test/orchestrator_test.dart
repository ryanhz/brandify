import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:brandify/src/capture/orchestrator.dart';
import 'package:brandify/src/capture/server.dart';
import 'package:brandify/src/config.dart';
import 'package:brandify/src/device/device.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/process.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

class FakeSession implements DeviceSession {
  int teardowns = 0;
  @override
  String get flutterDeviceId => 'fake-1';
  @override
  Map<String, Object?> get info => {'model': 'Fake'};
  @override
  Future<Uint8List> screenshot() async => img.encodePng(img.Image(width: 10, height: 20));
  @override
  Future<void> teardown() async => teardowns++;
}

class FakeDriver implements DeviceDriver {
  FakeDriver(this.config, this.session);
  @override
  final DeviceConfig config;
  final FakeSession session;
  @override
  Future<DeviceSession> prepare({required int port}) async => session;
}

/// Plays the device side of the protocol, like brandify_flutter would.
Future<int> fakeTest(List<String> args, List<String> shots,
    {bool sayDone = true, int exit = 0}) async {
  String define(String k) =>
      args.firstWhere((a) => a.startsWith('--dart-define=$k=')).split('=').last;
  final port = int.parse(define('BRANDIFY_PORT'));
  final run = define('BRANDIFY_RUN');
  final c = HttpClient();
  Future<void> post(String path, [Map<String, String> q = const {}]) async {
    final req = await c.postUrl(Uri(
        scheme: 'http', host: '127.0.0.1', port: port, path: path,
        queryParameters: {'run': run, ...q}));
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode != 200) throw StateError('$path ${res.statusCode}');
  }

  await post('/hello', {'v': '$captureProtocolVersion', 'dpr': '2.625', 'w': '1080', 'h': '2400'});
  for (final s in shots) {
    await post('/shot', {'name': s});
  }
  if (sayDone) await post('/done');
  c.close();
  return exit;
}

void main() {
  late Directory root;
  late FakeSession session;
  late FakeRunner runner;
  late List<String> testShots;
  late bool sayDone;
  late int exit;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('bp_orch');
    Directory(p.join(root.path, 'integration_test')).createSync();
    File(p.join(root.path, 'integration_test', 'brandify_test.dart')).writeAsStringSync('');
    session = FakeSession();
    runner = FakeRunner();
    testShots = ['home', 'detail'];
    sayDone = true;
    exit = 0;
    runner.onStart = (exe, args) => FakeProcess(body: (proc) async {
          proc.writeln('00:01 +0: store screenshots');
          return fakeTest(args, testShots, sayDone: sayDone, exit: exit);
        });
  });
  tearDown(() => root.delete(recursive: true));

  CaptureOrchestrator orchestrator() {
    final config = BrandifyConfig.parse('''
locales: [en-US, de-DE]
devices: [{id: phone, platform: android, serial: x}, {id: iphone, platform: ios, simulator: iPhone 17}]
capture: {port: 47999, stable_interval_ms: 0}
''', root: root.path);
    return CaptureOrchestrator(
      config: config,
      runner: runner,
      logger: Logger(out: _Null(), err: _Null()),
      driverFactory: (d) => FakeDriver(d, session),
      isMacOS: false,
    );
  }

  test('runs every locale on the device, writes PNGs and manifest, tears down once', () async {
    final results = await orchestrator().run();
    expect(results.map((r) => r.locale), ['en-US', 'de-DE']);
    expect(session.teardowns, 1);
    expect(runner.started, hasLength(2));
    expect(runner.started.first,
        allOf(startsWith('flutter test integration_test/brandify_test.dart -d fake-1 --no-pub'),
            contains('--dart-define=BRANDIFY_LOCALE=en-US')));
    final dir = p.join(root.path, 'build/brandify/raw/phone/de-DE');
    expect(File(p.join(dir, 'home.png')).existsSync(), isTrue);
    final manifest = jsonDecode(File(p.join(dir, 'manifest.json')).readAsStringSync()) as Map;
    expect(manifest['locale'], 'de-DE');
    expect(manifest['view'], {'dpr': 2.625, 'width': 1080, 'height': 2400});
    expect((manifest['shots'] as List).map((s) => (s as Map)['name']), ['home', 'detail']);
    expect(((manifest['shots'] as List).first as Map)['attempts'], 2);
  });

  test('stale shots from an earlier run are removed', () async {
    final stale = File(p.join(root.path, 'build/brandify/raw/phone/en-US/old.png'))
      ..createSync(recursive: true);
    await orchestrator().run(locales: {'en-US'});
    expect(stale.existsSync(), isFalse);
  });

  test('a failing test is reported with its output, and the device is torn down', () async {
    exit = 1;
    await expectLater(
        orchestrator().run(),
        throwsA(isA<BrandifyException>().having((e) => e.message, 'm',
            allOf(contains('failed (exit 1)'), contains('store screenshots')))));
    expect(session.teardowns, 1);
  });

  test('a test that never says done is an error', () async {
    sayDone = false;
    await expectLater(orchestrator().run(),
        throwsA(isA<BrandifyException>().having((e) => e.message, 'm', contains('without finishing'))));
  });

  test('iOS devices are skipped off macOS unless asked for', () async {
    final results = await orchestrator().run(locales: {'en-US'});
    expect(results.map((r) => r.deviceId), ['phone']);
  });

  test('unknown --device is rejected before anything boots', () async {
    await expectLater(orchestrator().run(devices: {'tablet'}),
        throwsA(isA<BrandifyException>().having((e) => e.message, 'm', contains('Unknown device tablet'))));
    expect(session.teardowns, 0);
  });
}

class _Null implements IOSink {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
