// The Google Play feature graphic: job parsing and the rendered PNG.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:brandify_flutter/src/frame/ads_adapter.dart';
import 'package:brandify_flutter/src/frame/feature_graphic.dart';
import 'package:brandify_flutter/src/frame/job.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _bg = Color(0xFF0E2E28);
const _logoColor = Color(0xFFFF00FF);

Future<ui.Image> _solid(WidgetTester tester, int size, Color color) async =>
    (await tester.runAsync(() {
      final rec = ui.PictureRecorder();
      ui.Canvas(rec).drawRect(ui.Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()), ui.Paint()..color = color);
      return rec.endRecording().toImage(size, size);
    }))!;

/// The PNG at [path]: size and RGBA bytes.
Future<(int, int, Uint8List)> _decode(WidgetTester tester, String path) async =>
    (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(File(path).readAsBytesSync());
      final image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final r = (image.width, image.height, data!.buffer.asUint8List());
      image.dispose();
      return r;
    }))!;

bool _near(Uint8List px, int i, Color c, [int tol = 6]) =>
    (px[i] - (c.r * 255).round()).abs() <= tol &&
    (px[i + 1] - (c.g * 255).round()).abs() <= tol &&
    (px[i + 2] - (c.b * 255).round()).abs() <= tol;

void main() {
  late Directory tmp;
  setUpAll(() async {
    await initializeFraming(); // loads the default text face
    tmp = Directory.systemTemp.createTempSync('bf_fg');
  });
  tearDownAll(() => tmp.deleteSync(recursive: true));

  test('job v2: feature graphics with their resolved style; v1 is refused', () {
    final job = FrameJob.fromJson({
      'brandify_frame_job': 2,
      'style': {'template': 'caption_top', 'background': [0xFFFFFFFF], 'device': 'screen'},
      'items': [],
      'feature_graphic': {
        'style': {'background': [0xFF000000, 0xFF111111], 'text_color': 0xFFFFFFFF, 'logo': '/l.png'},
        'items': [
          {'locale': 'en-US', 'out': '/o.png', 'text': {'headline': 'Acme', 'subheadline': 'Tasks'}},
        ],
      },
    });
    expect(job.items, isEmpty);
    expect(job.featureGraphicStyle.background, const [Color(0xFF000000), Color(0xFF111111)]);
    expect(job.featureGraphicStyle.textColor, const Color(0xFFFFFFFF));
    expect(job.featureGraphicStyle.logo, '/l.png');
    expect(job.featureGraphicStyle.font, isNull);
    final fg = job.featureGraphics.single;
    expect((fg.locale, fg.out, fg.text.headline, fg.text.subheadline), ('en-US', '/o.png', 'Acme', 'Tasks'));

    final old = FrameJob.fromJson({
      'brandify_frame_job': 2,
      'style': {'template': 'caption_top', 'background': [0xFFFFFFFF], 'device': 'screen'},
      'items': [],
    });
    expect(old.featureGraphics, isEmpty, reason: 'no feature_graphic block');
    expect(
        () => FrameJob.fromJson({'brandify_frame_job': 1, 'style': {}, 'items': []}),
        throwsA(isA<StateError>().having((e) => e.message, 'message', contains('matching versions'))));
  });

  test('long text shrinks to fit, short text keeps the largest size', () {
    const style = TextStyle(fontSize: 10);
    expect(fitFontSize('Acme', style, 500, max: 68, min: 36, maxLines: 2), 68);
    final long = fitFontSize('A very long application name that goes on and on and on', style, 500,
        max: 68, min: 36, maxLines: 2);
    expect(long, lessThan(68));
    expect(long, greaterThanOrEqualTo(36));
  });

  for (final withLogo in [true, false]) {
    testWidgets('renders 1024×500 ${withLogo ? 'with the logo' : 'text only'}: edges clear, text drawn',
        (tester) async {
      final out = '${tmp.path}/${withLogo ? 'logo' : 'text'}.png';
      final logo = withLogo ? await _solid(tester, 512, _logoColor) : null;
      await renderFeatureGraphic(
          tester,
          FeatureGraphicItem(locale: 'en-US', out: out, text: const FrameCaption('Morse Codec', 'Send and decode Morse code')),
          const FeatureGraphicStyle(background: [_bg], textColor: Color(0xFFFFFFFF)),
          logo);
      logo?.dispose();

      final (w, h, px) = await _decode(tester, out);
      expect((w, h), (1024, 500));
      int at(int x, int y) => (y * w + x) * 4;
      // The padding is only background, on every side.
      for (final (x, y) in [(0, 0), (1023, 0), (0, 499), (1023, 499), (40, 250), (980, 250), (512, 20), (512, 480)]) {
        expect(_near(px, at(x, y), _bg), isTrue, reason: 'pixel ($x, $y) should be background');
      }
      var white = 0, magenta = 0;
      for (var i = 0; i < px.length; i += 4) {
        if (_near(px, i, const Color(0xFFFFFFFF), 30)) white++;
        if (_near(px, i, _logoColor)) magenta++;
      }
      expect(white, greaterThan(2000), reason: 'the text');
      expect(magenta > 30000, withLogo, reason: 'the logo, about 232×232 px');
    });
  }
}
