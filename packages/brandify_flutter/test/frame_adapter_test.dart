// The framing adapter's rules, each a test (see lib/src/frame/ads_adapter.dart).
//
// The pixel tests frame a synthetic capture: a pure red "status bar" band
// over a pure green body, on a pure blue background. Anything the frame
// draws over the screen (a status bar overlay, a camera cutout) shows up as
// a pixel that is not red, green or a red/green blend. Controls run the same
// check on outputs made with their overlay and a cutout and require it to
// fail, so the check can't pass vacuously.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:app_deploy_screenshots/app_deploy_screenshots.dart';
import 'package:brandify_flutter/src/frame/ads_adapter.dart';
import 'package:brandify_flutter/src/frame/job.dart';
import 'package:brandify_flutter/src/frame/layout.dart';
import 'package:flutter/widgets.dart' hide Image;
import 'package:flutter_test/flutter_test.dart';

const _red = ui.Color(0xFFFF0000);
const _green = ui.Color(0xFF00FF00);
const _blue = ui.Color(0xFF0000FF);

FrameItem _item(String name, {required bool ios, required int w, required int h,
        required double dpr, required Size canvas, required String out, FrameCaption? caption}) =>
    FrameItem(
      device: name, locale: 'en-US', shot: 'home', ios: ios, raw: '', out: out,
      width: w, height: h, dpr: dpr,
      slot: ios ? 'appstore_iphone_69' : 'play_phone',
      canvas: canvas,
      caption: caption,
    );

/// Red band of [band] px over green, [w]×[h].
Future<ui.Image> _synthetic(WidgetTester tester, int w, int h, int band) async =>
    (await tester.runAsync(() {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec);
      c.drawRect(ui.Rect.fromLTWH(0, 0, w.toDouble(), band.toDouble()), ui.Paint()..color = _red);
      c.drawRect(ui.Rect.fromLTWH(0, band.toDouble(), w.toDouble(), (h - band).toDouble()),
          ui.Paint()..color = _green);
      return rec.endRecording().toImage(w, h);
    }))!;

class _Decoded {
  _Decoded(this.width, this.height, this.rgba);
  final int width, height;
  final Uint8List rgba;
}

Future<_Decoded> _decode(WidgetTester tester, String path) async =>
    (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
      final img = (await codec.getNextFrame()).image;
      final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
      return _Decoded(img.width, img.height, data!.buffer.asUint8List());
    }))!;

/// Bounding box of the pure red/green (screen) pixels: (left, top, right, bottom).
(int, int, int, int) _screenBox(_Decoded d) {
  final px = d.rgba;
  var x0 = d.width, y0 = d.height, x1 = -1, y1 = -1;
  for (var y = 0; y < d.height; y++) {
    for (var x = 0; x < d.width; x++) {
      final i = (y * d.width + x) * 4;
      final red = px[i] > 240 && px[i + 1] < 15 && px[i + 2] < 15;
      final green = px[i + 1] > 240 && px[i] < 15 && px[i + 2] < 15;
      if (red || green) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  return (x0, y0, x1, y1);
}

class _ScreenCheck {
  _ScreenCheck(this.redPixels, this.foreign);
  final int redPixels;

  /// Pixels inside the screen that the capture could not have produced.
  final int foreign;
}

_ScreenCheck _checkScreen(_Decoded d) {
  final px = d.rgba;
  bool pureRed(int i) => px[i] > 240 && px[i + 1] < 15 && px[i + 2] < 15;
  bool pureGreen(int i) => px[i + 1] > 240 && px[i] < 15 && px[i + 2] < 15;
  var x0 = d.width, y0 = d.height, x1 = -1, y1 = -1, red = 0;
  for (var y = 0; y < d.height; y++) {
    for (var x = 0; x < d.width; x++) {
      final i = (y * d.width + x) * 4;
      final r = pureRed(i);
      if (r) red++;
      if (r || pureGreen(i)) {
        if (x < x0) x0 = x;
        if (x > x1) x1 = x;
        if (y < y0) y0 = y;
        if (y > y1) y1 = y;
      }
    }
  }
  expect(x1, greaterThan(x0), reason: 'no screen found in the output');
  // Rounded screen corners blend with the background or bezel: skip a
  // small square at each corner, and the 1 px anti-aliased rim.
  final corner = ((x1 - x0) * 0.06).ceil();
  var foreign = 0;
  for (var y = y0 + 1; y < y1; y++) {
    for (var x = x0 + 1; x < x1; x++) {
      final inCornerX = x < x0 + corner || x > x1 - corner;
      final inCornerY = y < y0 + corner || y > y1 - corner;
      if (inCornerX && inCornerY) continue;
      final i = (y * d.width + x) * 4;
      final ok = px[i + 2] < 16 && px[i] + px[i + 1] >= 220;
      if (!ok) foreign++;
    }
  }
  return _ScreenCheck(red, foreign);
}

final _cases = <({String name, bool ios, int w, int h, double dpr, Size canvas, int band})>[
  (name: 'android', ios: false, w: 1080, h: 2400, dpr: 2.625, canvas: const Size(1080, 1920), band: 132),
  (name: 'ios', ios: true, w: 1320, h: 2868, dpr: 3, canvas: const Size(1320, 2868), band: 186),
];

void main() {
  late Directory tmp;
  setUpAll(() async {
    await initializeFraming();
    // BRANDIFY_TEST_OUT keeps the images for a look.
    final keep = Platform.environment['BRANDIFY_TEST_OUT'];
    tmp = keep != null
        ? (Directory(keep)..createSync(recursive: true))
        : Directory.systemTemp.createTempSync('bp_frame');
  });
  tearDownAll(() {
    if (Platform.environment['BRANDIFY_TEST_OUT'] == null) tmp.deleteSync(recursive: true);
  });

  test('only ads_adapter.dart imports app_deploy_screenshots', () {
    final importers = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .where((f) => f.readAsStringSync().contains('package:app_deploy_screenshots/'))
        .map((f) => f.path.replaceAll(r'\', '/'))
        .toList();
    expect(importers, ['lib/src/frame/ads_adapter.dart']);
  });

  test('virtual device is exactly the capture, at the device dpr', () {
    for (final (w, h, dpr) in [(1080, 2400, 2.625), (1320, 2868, 3.0), (1440, 3120, 3.5), (1080, 2340, 2.75)]) {
      final d = captureDevice(_item('x', ios: false, w: w, h: h, dpr: dpr, canvas: const Size(1, 1), out: ''));
      expect(d.devicePixelRatio, dpr);
      expect(d.size.width * dpr, closeTo(w, 1e-9), reason: '$w×$h @ $dpr');
      expect(d.size.height * dpr, closeTo(h, 1e-9), reason: '$w×$h @ $dpr');
    }
  });

  test('no device style draws a camera cutout', () {
    for (final s in FrameDevice.values) {
      expect(deviceStyle(s).cutout, ScreenCutout.none, reason: s.name);
    }
  });

  test('canvas size is the item\'s store slot', () {
    final item = _item('x', ios: false, w: 1080, h: 2400, dpr: 2.625, canvas: const Size(1080, 1920), out: '');
    expect(marketingFrame(item, const FrameStyle()).canvasSize, const Size(1080, 1920));
  });

  for (final c in _cases) {
    for (final style in FrameDevice.values) {
      testWidgets('${c.name} ${style.name}: canvas = slot, screen untouched (no status bar, no cutout)',
          (tester) async {
        final out = '${tmp.path}/${c.name}_${style.name}.png';
        final item = _item(c.name, ios: c.ios, w: c.w, h: c.h, dpr: c.dpr, canvas: c.canvas, out: out);
        final image = await _synthetic(tester, c.w, c.h, c.band);
        await frameCapture(tester, item, FrameStyle(background: const [_blue], device: style), image);

        final d = await _decode(tester, out);
        expect((d.width, d.height), (c.canvas.width.toInt(), c.canvas.height.toInt()));
        final check = _checkScreen(d);
        expect(check.redPixels, greaterThan(0), reason: 'the real status bar band is gone');
        expect(check.foreign, 0, reason: 'something was drawn over the screen');
      });
    }

    testWidgets('${c.name} control: their status bar overlay fails the screen check', (tester) async {
      final out = '${tmp.path}/${c.name}_control_overlay.png';
      final item = _item(c.name, ios: c.ios, w: c.w, h: c.h, dpr: c.dpr, canvas: c.canvas, out: out);
      final image = await _synthetic(tester, c.w, c.h, c.band);
      await tester.pumpWidget(CaptureView(image));
      await tester.pump();
      final dev = captureDevice(item);
      await AppDeployScreenshots.byDevice(tester, 'home',
          device: Device(
            name: dev.name,
            size: dev.size,
            devicePixelRatio: dev.devicePixelRatio,
            platform: dev.platform,
            type: dev.type,
            safeArea: EdgeInsets.only(top: c.band / c.dpr),
          ),
          fileName: out,
          statusBar: const StatusBarOverlay(time: '9:41'),
          frame: ScreenshotFrame.builder(
              (_) => marketingFrame(item, const FrameStyle(background: [_blue]))));
      final check = _checkScreen(await _decode(tester, out));
      printOnFailure('foreign: ${check.foreign}');
      debugPrint('${c.name} overlay control: ${check.foreign} foreign pixels');
      expect(check.foreign, greaterThan(0));
    });

    testWidgets('${c.name} control: a drawn cutout fails the screen check', (tester) async {
      final out = '${tmp.path}/${c.name}_control_cutout.png';
      final item = _item(c.name, ios: c.ios, w: c.w, h: c.h, dpr: c.dpr, canvas: c.canvas, out: out);
      final image = await _synthetic(tester, c.w, c.h, c.band);
      await tester.pumpWidget(CaptureView(image));
      await tester.pump();
      await AppDeployScreenshots.byDevice(tester, 'home',
          device: captureDevice(item),
          fileName: out,
          frame: ScreenshotFrame.builder((_) => MarketingFrame(
                background: const FrameBackground.solid(_blue),
                device: DeviceStyle.screenOnly(
                    cutout: c.ios ? ScreenCutout.island : ScreenCutout.punchHole),
                canvasSize: c.canvas,
              )));
      final check = _checkScreen(await _decode(tester, out));
      debugPrint('${c.name} cutout control: ${check.foreign} foreign pixels');
      expect(check.foreign, greaterThan(0));
    });
  }

  // Template contract (caption_top): with captions of very different
  // lengths, every slide of a device shows the identical phone, whole, above
  // a bottom margin, close under the tallest caption.
  const contractCaptions = [
    FrameCaption('Hi'),
    FrameCaption('Everything in one place', 'Plan your day in seconds'),
    FrameCaption('Your whole week, planned and shared with the team',
        'Tasks, reminders and notes in one calm list'),
  ];
  for (final c in _cases) {
    for (final device in FrameDevice.values) {
      testWidgets('caption_top contract, ${c.name} ${device.name}: same whole phone for every caption',
          (tester) async {
        final style = FrameStyle(background: const [_blue], device: device);
        final items = [
          for (final (n, caption) in contractCaptions.indexed)
            _item(c.name, ios: c.ios, w: c.w, h: c.h, dpr: c.dpr, canvas: c.canvas,
                out: '${tmp.path}/contract_${c.name}_${device.name}_$n.png', caption: caption),
        ];
        final plan = planCaptions(items, style)[c.name]!;
        final boxes = <(int, int, int, int)>[];
        late _Decoded tallest;
        for (final item in items) {
          await frameCapture(tester, item, style, await _synthetic(tester, c.w, c.h, c.band),
              captions: plan);
          final d = await _decode(tester, item.out);
          boxes.add(_screenBox(d));
          tallest = d;
        }
        expect(boxes.toSet(), hasLength(1), reason: 'phone moved or resized: $boxes');
        _expectPlacedAndWhole(boxes.first, captionTopPlacement(items.first, style, plan));
        _expectSnugUnderCaption(tallest, boxes.first, c.canvas);
      });
    }
  }

  // The same on real captures. Geometry doesn't depend on the pixels, but
  // here the phone is found as "not background" and the check includes its
  // bottom corners being drawn (not cut off by the canvas edge).
  final realCaptures = [
    (file: 'test/fixtures/pixel_home_1080x2400.png', ios: false, dpr: 2.625, canvas: const Size(1080, 1920)),
    (file: 'test/fixtures/iphone69_home_1320x2868.png', ios: true, dpr: 3.0, canvas: const Size(1320, 2868)),
  ];
  for (final r in realCaptures) {
    final exists = File(r.file).existsSync();
    for (final device in FrameDevice.values) {
      testWidgets('caption_top on a real capture, ${r.file.split('/').last} ${device.name}: '
          'phone whole above the bottom margin, snug under the caption'
          '${exists ? '' : ' (SKIPPED: add ${r.file}, a real capture)'}', (tester) async {
        final raw = await tester.runAsync(() async {
          final codec = await ui.instantiateImageCodec(await File(r.file).readAsBytes());
          return (await codec.getNextFrame()).image;
        });
        final style = FrameStyle(background: const [_blue], device: device);
        final items = [
          for (final (n, caption) in contractCaptions.indexed)
            _item('real', ios: r.ios, w: raw!.width, h: raw.height, dpr: r.dpr, canvas: r.canvas,
                out: '${tmp.path}/real_${r.ios ? 'ios' : 'android'}_${device.name}_$n.png',
                caption: caption),
        ];
        final plan = planCaptions(items, style)['real']!;
        final placement = captionTopPlacement(items.first, style, plan);
        final boxes = <(int, int, int, int)>[];
        late _Decoded tallest;
        for (final item in items) {
          await frameCapture(tester, item, style, raw!, captions: plan);
          final d = await _decode(tester, item.out);
          expect((d.width, d.height), (r.canvas.width.toInt(), r.canvas.height.toInt()));
          boxes.add(_phoneBox(d, belowY: placement.screenTop.floor() - placement.bezel.ceil() - 2));
          tallest = d;
        }
        expect(boxes.toSet(), hasLength(1), reason: 'phone moved or resized: $boxes');
        final (x0, y0, x1, y1) = boxes.first;
        final margin = marginPoints * placement.unit;
        expect(y1, lessThanOrEqualTo(r.canvas.height - margin + 2), reason: 'phone not above the margin');
        expect(y1 - y0 + 1, closeTo(placement.deviceBottom - placement.screenTop + placement.bezel, 3));
        expect(x1 - x0 + 1, closeTo(placement.screenWidth + 2 * placement.bezel, 3));
        // Rounded bottom corners are on the canvas: the phone's last row is
        // narrower than its middle row.
        expect(_rowWidth(tallest, y1), lessThan(_rowWidth(tallest, (y0 + y1) ~/ 2) - 4));
        _expectSnugUnderCaption(tallest, (x0, y0, x1, y1), r.canvas);
      }, skip: !exists);
    }
  }

  test('caption_area set: the caption runs to that share; a taller caption fails, naming the slide', () {
    const long = FrameCaption(
        'This headline goes on and on and on, far longer than any store caption should',
        'and then a subheadline adds even more words to push it past the caption area');
    final item = _item('pixel', ios: false, w: 1080, h: 2400, dpr: 2.625,
        canvas: const Size(1080, 1920), out: '', caption: long);
    expect(
        () => planCaptions([item], const FrameStyle(captionArea: 0.22)),
        throwsA(isA<CaptionOverflow>()
            .having((e) => '$e', 'message', contains('pixel en-US "home"'))
            .having((e) => '$e', 'message', contains('caption_area is 22 %'))));
    // Auto sizes the area to fit it.
    expect(planCaptions([item], const FrameStyle())['pixel'], isNotNull);
    // An explicit area puts the device top at that share of the height.
    final short = _item('pixel', ios: false, w: 1080, h: 2400, dpr: 2.625,
        canvas: const Size(1080, 1920), out: '', caption: const FrameCaption('Hi'));
    const style = FrameStyle(captionArea: 0.3);
    final p = captionTopPlacement(short, style, planCaptions([short], style)['pixel']);
    expect(p.screenTop, closeTo(0.3 * 1920, 0.5));
  });

  test('caption_top placement: whole device above the bottom margin', () {
    final p = CaptionTopPlacement.of(
        canvas: const Size(1320, 2868), captureWidth: 1320, captureHeight: 2868, dpr: 3,
        captionHeight: 400);
    expect(p.unit, closeTo(3, 1e-9));
    expect(p.deviceBottom, closeTo(2868 - 24 * 3, 1e-6)); // height-bound: on the margin
    final squat = CaptionTopPlacement.of(
        canvas: const Size(1080, 1920), captureWidth: 1080, captureHeight: 1440, dpr: 2,
        captionHeight: 100);
    expect(squat.screenWidth, closeTo((1080 - 2 * 24 * squat.unit) * 0.86, 1e-6)); // width-bound
    expect(squat.deviceBottom, lessThan(1920 - 24 * squat.unit));
  });
}

void _expectPlacedAndWhole((int, int, int, int) box, CaptionTopPlacement p) {
  final (x0, y0, x1, y1) = box;
  expect(x1 - x0 + 1, closeTo(p.screenWidth, 2), reason: 'screen width vs placement');
  expect(y0, closeTo(p.screenTop, 2), reason: 'screen top vs placement');
  expect(y1 + 1, closeTo(p.screenBottom, 2), reason: 'screen bottom vs placement');
  expect(p.deviceBottom, lessThanOrEqualTo(p.canvas.height - marginPoints * p.unit + 0.5),
      reason: 'device must end above the bottom margin');
}

/// The gap from the last caption ink to the phone is their caption-to-device
/// gap plus at most the spacer line: no more than 6 % of the height.
void _expectSnugUnderCaption(_Decoded d, (int, int, int, int) phone, Size canvas) {
  final (_, top, _, _) = phone;
  var inkBottom = -1;
  for (var y = 0; y < top - 2; y++) {
    for (var x = 0; x < d.width; x++) {
      final i = (y * d.width + x) * 4;
      if (d.rgba[i] > 90 && d.rgba[i + 1] > 90) inkBottom = y; // white-ish text on blue
    }
  }
  expect(inkBottom, greaterThan(0), reason: 'no caption found');
  final gap = top - inkBottom;
  expect(gap, greaterThan(0));
  expect(gap / canvas.height, lessThan(0.06), reason: 'gap of $gap px under the caption');
}

/// Bounding box of everything that isn't the blue background or its shadow,
/// below [belowY] (skips the caption).
(int, int, int, int) _phoneBox(_Decoded d, {required int belowY}) {
  var x0 = d.width, y0 = d.height, x1 = -1, y1 = -1;
  for (var y = math.max(0, belowY); y < d.height; y++) {
    for (var x = 0; x < d.width; x++) {
      if (_isBackground(d, x, y)) continue;
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
    }
  }
  return (x0, y0, x1, y1);
}

bool _isBackground(_Decoded d, int x, int y) {
  final i = (y * d.width + x) * 4;
  // The blue background, and the shadow darkening it.
  return d.rgba[i] < 40 && d.rgba[i + 1] < 40 && d.rgba[i + 2] > 120;
}

int _rowWidth(_Decoded d, int y) {
  var n = 0;
  for (var x = 0; x < d.width; x++) {
    if (!_isBackground(d, x, y)) n++;
  }
  return n;
}
