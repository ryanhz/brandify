import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/config.dart';
import 'package:brandify/src/frame/frame_job.dart';
import 'package:brandify/src/frame/frame_runner.dart';
import 'package:brandify/src/logger.dart';
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

Matcher throwsBp(String fragment) =>
    throwsA(isA<BrandifyException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  group('store slots', () {
    test('Android: Play phone 9:16 at the capture width', () {
      final s = slotFor(DevicePlatform.android, 1080, 2400);
      expect((s.id, s.width, s.height), ('play_phone', 1080, 1920));
      expect(slotFor(DevicePlatform.android, 1440, 3120).height, 2560);
    });
    test('iOS: the display class that accepts the capture size', () {
      expect(slotFor(DevicePlatform.ios, 1320, 2868).id, 'appstore_iphone_69');
      expect(slotFor(DevicePlatform.ios, 1290, 2796).id, 'appstore_iphone_69');
      expect(slotFor(DevicePlatform.ios, 1284, 2778).id, 'appstore_iphone_65');
      expect(slotFor(DevicePlatform.ios, 2064, 2752).id, 'appstore_ipad_13');
      final s = slotFor(DevicePlatform.ios, 1320, 2868);
      expect((s.width, s.height), (1320, 2868));
    });
    test('rejects what no slot takes', () {
      expect(() => slotFor(DevicePlatform.ios, 1179, 2556), throwsBp('6.9"'));
      expect(() => slotFor(DevicePlatform.android, 2400, 1080), throwsBp('landscape'));
      expect(() => slotFor(DevicePlatform.android, 2400, 5000), throwsBp('320–3840'));
    });
  });

  group('frame', () {
    late Directory root;
    late _Sink out, err;
    late Logger logger;

    BrandifyConfig config(String frame) => BrandifyConfig.parse('''
locales: [en-US, de-DE]
devices:
  - {id: pixel, platform: android, avd: a}
  - {id: iphone, platform: ios, simulator: "iPhone 17 Pro Max"}
$frame
''', root: root.path);

    void capture(String device, String locale, List<String> shots,
        {int w = 1080, int h = 2400, bool withView = true}) {
      final dir = Directory(p.join(root.path, 'build/brandify/raw', device, locale))
        ..createSync(recursive: true);
      for (final s in shots) {
        File(p.join(dir.path, '$s.png')).writeAsBytesSync(img.encodePng(img.Image(width: w, height: h)));
      }
      File(p.join(dir.path, 'manifest.json')).writeAsStringSync(jsonEncode({
        'brandify_manifest': 1,
        'device': device,
        'locale': locale,
        if (withView) 'view': {'dpr': 2.625, 'width': w, 'height': h},
        'shots': [for (final s in shots) {'name': s, 'file': '$s.png', 'width': w, 'height': h}],
      }));
    }

    setUp(() {
      root = Directory.systemTemp.createTempSync('bp_frame');
      out = _Sink();
      err = _Sink();
      logger = Logger(out: out, err: err);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('job pairs each shot with dpr, slot and caption; skips uncaptured pairs', () {
      capture('pixel', 'en-US', ['home', 'add_task']);
      capture('pixel', 'de-DE', ['home', 'add_task']);
      final job = FrameJob.build(config('''
frame:
  background: ['#000000', '#FFFFFF']
  captions:
    en-US: {home: Hello, add_task: {headline: Add, subheadline: Fast}, setings: Typo}
    de-DE: {home: Hallo, add_task: Neu}
'''), logger: logger);
      expect(job.items.map((i) => '${i.device} ${i.locale} ${i.shot}'),
          ['pixel en-US home', 'pixel en-US add_task', 'pixel de-DE home', 'pixel de-DE add_task']);
      final j = jsonDecode(job.encode()) as Map<String, Object?>;
      expect(j['brandify_frame_job'], frameJobVersion);
      expect(j['style'], {
        'template': 'caption_top',
        'caption_area': null,
        'background': [0xFF000000, 0xFFFFFFFF],
        'device': 'screen',
      });
      final first = (j['items'] as List).first as Map;
      expect(first['dpr'], 2.625);
      expect(first['canvas'], {'width': 1080, 'height': 1920});
      expect(first['slot'], 'play_phone');
      expect(first['caption'], {'headline': 'Hello'});
      expect(first['out'], p.join(root.path, 'build/brandify/framed/pixel/en-US/home.png'));
      expect(((j['items'] as List)[1] as Map)['caption'], {'headline': 'Add', 'subheadline': 'Fast'});
      expect(out.lines.join('\n'), contains('[iphone en-US] no capture yet; skipped'));
      expect(err.lines.join('\n'), contains('setings'));
    });

    test('a capture without dpr asks for a new capture', () {
      capture('pixel', 'en-US', ['home'], withView: false);
      expect(() => FrameJob.build(config(''), logger: logger), throwsBp('Run `brandify capture` again'));
    });

    test('captions must cover every captured locale and shot', () {
      capture('pixel', 'en-US', ['home', 'add_task']);
      capture('pixel', 'de-DE', ['home']);
      expect(() => FrameJob.build(config('frame: {captions: {en-US: {home: Hi}}}'), logger: logger),
          throwsBp('no caption for add_task'));
      expect(() => FrameJob.build(config('frame: {captions: {en-US: {home: Hi, add_task: Add}}}'), logger: logger),
          throwsBp('no `de-DE` entry'));
    });

    test('named device/locale must have a capture; nothing captured is an error', () {
      expect(() => FrameJob.build(config(''), logger: logger), throwsBp('Nothing to frame'));
      capture('pixel', 'en-US', ['home']);
      expect(() => FrameJob.build(config(''), devices: {'iphone'}, logger: logger),
          throwsBp('brandify capture -d iphone -l en-US'));
      expect(() => FrameJob.build(config(''), devices: {'nope'}, logger: logger), throwsBp('Unknown device'));
    });

    test('iOS capture off the slot table is rejected before running flutter', () {
      capture('iphone', 'en-US', ['home'], w: 1179, h: 2556);
      expect(() => FrameJob.build(config(''), logger: logger), throwsBp('No App Store screenshot slot'));
    });

    test('runner writes job + test, runs flutter test, checks output sizes', () async {
      capture('pixel', 'en-US', ['home']);
      final stale = File(p.join(root.path, 'build/brandify/framed/pixel/en-US/old.png'))
        ..createSync(recursive: true);
      final cfg = config('');
      final job = FrameJob.build(cfg, logger: logger);
      var canvas = (1080, 1920);
      final runner = FakeRunner([
        (exe, args) {
          final jobPath = args.last.split('=').last;
          final j = jsonDecode(File(jobPath).readAsStringSync()) as Map;
          for (final i in (j['items'] as List).cast<Map>()) {
            File(i['out'] as String).writeAsBytesSync(
                img.encodePng(img.Image(width: canvas.$1, height: canvas.$2)));
          }
          return ok('All tests passed!');
        },
      ]);
      final r = FrameRunner(config: cfg, runner: runner, logger: logger);
      await r.run(job);
      expect(stale.existsSync(), isFalse);
      expect(runner.calls.single,
          startsWith('flutter test build/brandify/frame/brandify_frame_test.dart --dart-define=BRANDIFY_FRAME_JOB='));
      expect(File(p.join(root.path, 'build/brandify/frame/brandify_frame_test.dart')).readAsStringSync(),
          contains('brandifyFrameMain()'));
      expect(out.lines.join('\n'), contains('Google Play phone (1080×1920): 1 framed'));

      canvas = (1080, 2400);
      await expectLater(r.run(job), throwsBp('needs 1080×1920'));
    });

    test('runner reports flutter test failures with a dependency hint', () async {
      capture('pixel', 'en-US', ['home']);
      final cfg = config('');
      final runner = FakeRunner([
        (exe, args) => CommandResult(1, utf8.encode(
            "Error: Couldn't resolve the package 'brandify_flutter' in 'package:brandify_flutter/frame.dart'."), ''),
      ]);
      await expectLater(
          FrameRunner(config: cfg, runner: runner, logger: logger).run(FrameJob.build(cfg, logger: logger)),
          throwsBp('add brandify_flutter to dev_dependencies'));
    });
  });
}
