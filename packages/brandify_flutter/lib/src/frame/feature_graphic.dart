// The Google Play feature graphic: 1024×500, the logo on the left and the
// app's name and tagline on the right (or the text alone, centred), on the
// frame background. Plain Flutter widgets, no app_deploy_screenshots: it is
// a banner, not a device frame. Rendered on the host by `brandify frame`.
//
// Play overlays a play button in the middle when the listing has a promo
// video and crops the edges in some places, so everything stays well inside
// the canvas ([featureGraphicPadding]) and the text shrinks to fit rather
// than run to the edge.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job.dart';

const featureGraphicSize = Size(1024, 500);

/// Space kept clear on every side.
const featureGraphicPadding = EdgeInsets.symmetric(horizontal: 88, vertical: 64);
const _logoSize = 232.0;
const _logoGap = 52.0;
const _headlineMax = 68.0, _headlineMin = 36.0;
const _subheadlineMax = 32.0, _subheadlineMin = 20.0;
const _lineGap = 14.0;

/// Default text face: the Roboto app_deploy_screenshots bundles and
/// `initializeFraming` loads, as for captions.
const _defaultFamily = TextStyle(fontFamily: 'AppDeployScreenshotsRoboto', fontFamilyFallback: ['Roboto']);

TextStyle _base(FeatureGraphicStyle style) => style.font == null
    ? _defaultFamily
    : const TextStyle(fontFamily: FeatureGraphicStyle.fontFamily);

TextStyle _weight(TextStyle s, FontWeight w) =>
    s.copyWith(fontWeight: w, fontVariations: [FontVariation.weight(w.value.toDouble())]);

/// The largest size from [max] down to [min] at which [text] fits in
/// [maxLines] lines of [width]; [min] if none does (it then wraps further).
double fitFontSize(String text, TextStyle style, double width,
    {required double max, required double min, required int maxLines, TextAlign align = TextAlign.start}) {
  for (var size = max; size > min; size -= 2) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style.copyWith(fontSize: size)),
      textDirection: TextDirection.ltr,
      textAlign: align,
      maxLines: maxLines,
    )..layout(maxWidth: width);
    final fits = !painter.didExceedMaxLines && painter.width <= width;
    painter.dispose();
    if (fits) return size;
  }
  return min;
}

class FeatureGraphic extends StatelessWidget {
  const FeatureGraphic({super.key, required this.style, required this.text, this.logo});

  final FeatureGraphicStyle style;
  final FrameCaption text;

  /// The decoded logo, or null for text only.
  final ui.Image? logo;

  @override
  Widget build(BuildContext context) {
    final inner = featureGraphicSize.width - featureGraphicPadding.horizontal;
    final textWidth = logo == null ? inner : inner - _logoSize - _logoGap;
    final align = logo == null ? TextAlign.center : TextAlign.start;
    final base = _base(style).copyWith(color: style.textColor);
    final headline = _weight(base, FontWeight.w700).copyWith(height: 1.1);
    final sub = _weight(base, FontWeight.w400).copyWith(
      height: 1.25,
      color: style.textColor.withValues(alpha: 0.85),
    );
    final headlineSize =
        fitFontSize(text.headline, headline, textWidth, max: _headlineMax, min: _headlineMin, maxLines: 2, align: align);
    final subSize = text.subheadline == null
        ? 0.0
        : math.min(
            headlineSize * 0.55,
            fitFontSize(text.subheadline!, sub, textWidth,
                max: _subheadlineMax, min: _subheadlineMin, maxLines: 2, align: align));

    final words = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: logo == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(text.headline, textAlign: align, style: headline.copyWith(fontSize: headlineSize)),
        if (text.subheadline != null) ...[
          const SizedBox(height: _lineGap),
          Text(text.subheadline!, textAlign: align, style: sub.copyWith(fontSize: math.max(_subheadlineMin, subSize))),
        ],
      ],
    );

    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        width: featureGraphicSize.width,
        height: featureGraphicSize.height,
        decoration: BoxDecoration(
          color: style.background.length == 1 ? style.background.single : null,
          gradient: style.background.length == 1
              ? null
              : LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: style.background),
        ),
        padding: featureGraphicPadding,
        alignment: Alignment.center,
        child: logo == null
            ? SizedBox(width: textWidth, child: words)
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // A soft shadow lifts the icon off a background it may share.
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(_logoSize * 0.22),
                      boxShadow: const [
                        BoxShadow(color: Color(0x40000000), blurRadius: 32, offset: Offset(0, 10)),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(_logoSize * 0.22),
                      child: SizedBox.square(
                        dimension: _logoSize,
                        child: RawImage(image: logo, fit: BoxFit.contain, filterQuality: FilterQuality.high),
                      ),
                    ),
                  ),
                  const SizedBox(width: _logoGap),
                  ConstrainedBox(constraints: BoxConstraints(maxWidth: textWidth), child: words),
                ],
              ),
      ),
    );
  }
}

Future<void> loadFeatureGraphicFont(String path) async {
  final bytes = await File(path).readAsBytes();
  await (FontLoader(FeatureGraphicStyle.fontFamily)..addFont(Future.value(ByteData.sublistView(bytes)))).load();
}

/// Renders [item]'s feature graphic to its PNG at `item.out`, one image pixel
/// per logical pixel.
Future<void> renderFeatureGraphic(
    WidgetTester tester, FeatureGraphicItem item, FeatureGraphicStyle style, ui.Image? logo) async {
  tester.view
    ..physicalSize = featureGraphicSize
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final key = GlobalKey();
  // flutter_test draws shadows as hard, unblurred shapes unless told
  // otherwise; it also checks the flag is back to true when the test ends.
  final Uint8List? bytes;
  debugDisableShadows = false;
  try {
    await tester.pumpWidget(RepaintBoundary(key: key, child: FeatureGraphic(style: style, text: item.text, logo: logo)));
    await tester.pump();
    final boundary = key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    bytes = await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 1);
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        return data!.buffer.asUint8List();
      } finally {
        image.dispose();
      }
    });
  } finally {
    debugDisableShadows = true;
  }
  File(item.out)
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(bytes!);
}
