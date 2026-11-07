// The only file in brandify that imports app_deploy_screenshots, so a 2.0
// change (several 1.x parameters are deprecated for removal) stays here.
// A test enforces this.
//
// brandify borrows their frame compositor (background, caption, layout,
// bezel, canvas size) and feeds it a real device capture instead of a
// widget-test render. Rules, each covered by test/frame_adapter_test.dart:
//
// 1. Never pass `statusBar`: their overlay would be stamped over the real
//    status bar ("9:0941", doubled icons).
// 2. No cutout that draws a camera hole: always `ScreenCutout.none`; a drawn
//    hole would sit on top of the real status bar.
// 3. The virtual device is exactly the capture: physical size = capture
//    size, dpr = the device's own. Their re-render is then lossless.
// 4. The canvas size is the store slot's, resolved by the CLI.
//
// Slide designs are templates (FrameTemplate): each one turns an item and
// the style into their MarketingFrame from their primitives (SlideLayout,
// DeviceStyle, FrameBackground, decorations). Only `caption_top` exists so
// far; its contract (same phone on every slide, whole, above a bottom
// margin) is tested too.
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:app_deploy_screenshots/app_deploy_screenshots.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'job.dart';
import 'layout.dart';

/// Sets up their pipeline for a host-side framing run. Real platform
/// channels: nothing app-specific runs here.
Future<void> initializeFraming() =>
    AppDeployScreenshots.initialize(mockPlatformChannels: false);

/// The virtual device their pipeline renders the capture on: one logical
/// point per `1/dpr` capture pixels, so `size * dpr` is exactly the capture.
Device captureDevice(FrameItem item) => Device(
      name: 'brandify_${item.device}',
      size: Size(item.width / item.dpr, item.height / item.dpr),
      devicePixelRatio: item.dpr,
      platform: item.ios ? DevicePlatform.ios : DevicePlatform.android,
      type: item.tablet ? DeviceType.tablet : DeviceType.phone,
      // Only read by their cutout and crop logic, both left off.
      safeArea: EdgeInsets.zero,
    );

/// Their device style for ours. The cutout is pinned to none (rule 2) even
/// though it is already the default for these constructors.
DeviceStyle deviceStyle(FrameDevice device) => switch (device) {
      FrameDevice.screen => const DeviceStyle.screenOnly(cutout: ScreenCutout.none),
      FrameDevice.bezel => const DeviceStyle(cutout: ScreenCutout.none),
    };

/// Bezel width in the device's points; theirs by default.
double bezelPoints(FrameDevice device) =>
    device == FrameDevice.bezel ? const DeviceBezel().width : 0;

/// The template's MarketingFrame for [item]. [captions] is the caption
/// plan shared by the device's slides, from [planCaptions]; without it,
/// [item] is planned on its own.
MarketingFrame marketingFrame(FrameItem item, FrameStyle style, {CaptionPlan? captions}) =>
    switch (style.template) {
      FrameTemplate.captionTop =>
        _captionTop(item, style, captions ?? planCaptions([item], style)[item.device]),
    };

// ---------------------------------------------------------------------------
// caption_top
//
// Their stacked `SlideLayout.captionTop`: caption at the top, then the whole
// device, as large as fits above a bottom margin. It sizes the device from
// the caption's measured height, so on its own a headline-only slide gets a
// bigger phone than a two-line one. The template makes every caption of a
// device exactly as tall, so the device is identical on every slide of that
// device, in every locale:
//
// - every caption gets the same lines: a subheadline line (invisible where
//   the slide has none) if any slide has one, and an invisible spacer line
//   last (their `footnote`) that takes up the difference. The text engine
//   rounds line heights to whole pixels while the 8 pt gaps between lines
//   are fractional, so only equal line structures can be padded exactly.
// - caption_area unset (auto): the tallest caption sets the height, so the
//   gap above the phone is as small as their layout allows.
// - caption_area set: that share of the canvas height runs from the top to
//   the device; a caption that needs more is an error.
//
// (An earlier version used their `bleed(visible: 1)` with a fixed area: the
// phone stood on the bottom edge with no margin, and short captions left a
// large gap.)
// ---------------------------------------------------------------------------

/// The caption layout every slide of one device shares.
class CaptionPlan {
  const CaptionPlan({required this.target, required this.subheadlineLine});

  /// Caption block height to pad to, canvas pixels (actual: within 0.5 px,
  /// the same on every slide).
  final double target;

  /// Whether every caption gets a subheadline line.
  final bool subheadlineLine;
}

/// Smallest spacer line, canvas pixels.
const _minSpacer = 1.0;

/// Per device id, the caption plan of its slides, or null when they have no
/// captions. Throws [CaptionOverflow] if a caption needs more than
/// `style.captionArea`.
Map<String, CaptionPlan?> planCaptions(List<FrameItem> items, FrameStyle style) {
  final plan = <String, CaptionPlan?>{};
  final byDevice = <String, List<FrameItem>>{};
  for (final i in items) {
    (byDevice[i.device] ??= []).add(i);
  }
  byDevice.forEach((device, list) {
    final captioned = list.where((i) => i.caption != null).toList();
    if (captioned.isEmpty) {
      plan[device] = null;
      return;
    }
    final canvas = captioned.first.canvas;
    final unit = unitFor(canvas);
    final withSub = captioned.any((i) => i.caption!.subheadline != null);
    double needs(FrameItem i) =>
        naturalCaptionHeight(_caption(i, style, withSub)!, canvas) + lineGapPoints * unit + _minSpacer;
    final area = style.captionArea;
    final reserved = (topPadPoints + gapPoints) * unit;
    if (area == null) {
      plan[device] = CaptionPlan(target: captioned.map(needs).reduce(math.max), subheadlineLine: withSub);
    } else {
      final target = area * canvas.height - reserved;
      for (final i in captioned) {
        final n = needs(i);
        if (n > target + 0.5) throw CaptionOverflow(i, (n + reserved) / canvas.height, area);
      }
      plan[device] = CaptionPlan(target: target, subheadlineLine: withSub);
    }
  });
  return plan;
}

/// [item]'s caption as laid out under [plan], or null without one.
Caption? captionFor(FrameItem item, FrameStyle style, CaptionPlan? plan) {
  final caption = _caption(item, style, plan?.subheadlineLine ?? false);
  if (caption == null) return null;
  if (plan == null) {
    throw StateError('brandify: ${item.device} has slides with and without captions.');
  }
  final unit = unitFor(item.canvas);
  final natural = naturalCaptionHeight(caption, item.canvas);
  final spacer = (plan.target - natural - lineGapPoints * unit).roundToDouble();
  if (spacer < _minSpacer) {
    // Planned without this slide; the planner normally catches this.
    final needed = natural + lineGapPoints * unit + _minSpacer + (topPadPoints + gapPoints) * unit;
    throw CaptionOverflow(item, needed / item.canvas.height, style.captionArea ?? 0);
  }
  return _withSpacer(caption, spacer, item.canvas);
}

/// The caption block height [item] gets under [plan], canvas pixels (0
/// without a caption).
double captionHeightFor(FrameItem item, FrameStyle style, CaptionPlan? plan) {
  final c = captionFor(item, style, plan);
  if (c == null) return 0;
  final unit = unitFor(item.canvas);
  return naturalCaptionHeight(c, item.canvas) +
      lineGapPoints * unit +
      _lineHeight(c.footnote!, _theirFootnote.merge(c.footnoteStyle), item.canvas);
}

MarketingFrame _captionTop(FrameItem item, FrameStyle style, CaptionPlan? plan) => MarketingFrame(
      background: _background(style),
      caption: captionFor(item, style, plan),
      slideLayout: SlideLayout.captionTop,
      device: deviceStyle(style.device),
      canvasSize: item.canvas,
    );

CaptionTopPlacement captionTopPlacement(FrameItem item, FrameStyle style, CaptionPlan? plan) =>
    CaptionTopPlacement.of(
      canvas: item.canvas,
      captureWidth: item.width,
      captureHeight: item.height,
      dpr: item.dpr,
      captionHeight: captionHeightFor(item, style, plan),
      bezelPoints: bezelPoints(style.device),
    );

FrameBackground _background(FrameStyle style) => style.background.length == 1
    ? FrameBackground.solid(style.background.single)
    : FrameBackground.gradient(LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: style.background,
      ));

Caption? _caption(FrameItem item, FrameStyle style, bool subheadlineLine) {
  final c = item.caption;
  if (c == null) return null;
  final font = style.font == null ? null : const TextStyle(fontFamily: FrameStyle.captionFontFamily);
  final placeholder = c.subheadline == null && subheadlineLine;
  return Caption(
    headline: c.headline,
    subheadline: placeholder ? '\u00A0' : c.subheadline,
    headlineStyle: font,
    subheadlineStyle: placeholder
        ? (font ?? const TextStyle()).copyWith(color: const Color(0x00000000))
        : font,
  );
}

/// [caption] plus an invisible last line (their footnote) [height] whole
/// canvas pixels tall.
Caption _withSpacer(Caption caption, double height, Size canvas) {
  final unit = unitFor(canvas);
  // A 1 pt non-breaking space: its line is fontSize * height tall, rounded
  // to whole pixels by the text engine, so [height] is whole pixels.
  TextStyle style(double h) => TextStyle(fontSize: 1, height: h, color: const Color(0x00000000));
  final h = height / unit;
  return Caption(
    headline: caption.headline,
    subheadline: caption.subheadline,
    footnote: '\u00A0',
    headlineStyle: caption.headlineStyle,
    subheadlineStyle: caption.subheadlineStyle,
    footnoteStyle: style(h),
  );
}

// Their caption text (1.2.1, `CaptionLayout`): sizes in caption points,
// scaled by [unitFor]; laid out at the width between the side margins;
// lines [lineGapPoints] apart; weights also set as a `wght` variation; in
// their bundled Roboto (`FontSetup.textFontFamily`, not exported). The
// template contract test fails if this drifts from what they draw.
const _theirFamily = TextStyle(fontFamily: 'AppDeployScreenshotsRoboto', fontFamilyFallback: ['Roboto']);
final _theirHeadline = _theirFamily.copyWith(fontSize: 30, fontWeight: FontWeight.w700, height: 1.15);
final _theirSubheadline = _theirFamily.copyWith(fontSize: 17, height: 1.3);
final _theirFootnote = _theirFamily.copyWith(fontSize: 11, height: 1.3);

double _lineHeight(String text, TextStyle style, Size canvas) {
  final unit = unitFor(canvas);
  final width = canvas.width - 2 * marginPoints * unit;
  final weight = style.fontWeight;
  if (weight != null && style.fontVariations == null) {
    style = style.copyWith(fontVariations: [FontVariation.weight(weight.value.toDouble())]);
  }
  final painter = TextPainter(
    text: TextSpan(
      style: style.copyWith(fontSize: (style.fontSize ?? 14) * unit),
      children: [TextSpan(text: text)],
    ),
    textAlign: TextAlign.center,
    textDirection: TextDirection.ltr,
  )..layout(minWidth: width, maxWidth: width);
  final h = painter.height;
  painter.dispose();
  return h;
}

/// Their caption block height for [caption] on [canvas], in canvas pixels
/// (headline and subheadline; no footnote).
double naturalCaptionHeight(Caption caption, Size canvas) {
  var h = _lineHeight(caption.headline, _theirHeadline.merge(caption.headlineStyle), canvas);
  if (caption.subheadline != null) {
    h += lineGapPoints * unitFor(canvas) +
        _lineHeight(caption.subheadline!, _theirSubheadline.merge(caption.subheadlineStyle), canvas);
  }
  return h;
}

/// A caption too tall for `frame.caption_area`.
class CaptionOverflow implements Exception {
  CaptionOverflow(this.item, this.needed, this.area);
  final FrameItem item;

  /// Share of the canvas height (top to device) the caption needs, and the
  /// share caption_area gives.
  final double needed, area;

  @override
  String toString() => 'brandify: the caption for ${item.device} ${item.locale} "${item.shot}" '
      'needs ${(needed * 100).ceil()} % of the canvas height, but frame.caption_area is '
      '${(area * 100).round()} %. Shorten it, raise caption_area, or remove caption_area to size '
      'the area from the tallest caption.';
}

/// Renders [image] (the decoded capture of [item]) into its framed PNG at
/// `item.out`.
Future<void> frameCapture(
    WidgetTester tester, FrameItem item, FrameStyle style, ui.Image image,
    {CaptionPlan? captions}) async {
  final frame = marketingFrame(item, style, captions: captions);
  await tester.pumpWidget(CaptureView(image));
  await tester.pump();
  await AppDeployScreenshots.byDevice(
    tester,
    item.shot,
    device: captureDevice(item),
    fileName: item.out,
    // statusBar: deliberately not passed (rule 1).
    frame: ScreenshotFrame.builder((_) => frame),
  );
}

/// The capture, one image pixel per physical pixel, no filtering.
class CaptureView extends StatelessWidget {
  const CaptureView(this.image, {super.key});
  final ui.Image image;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: TextDirection.ltr,
        child: SizedBox.expand(
          child: RawImage(image: image, fit: BoxFit.fill, filterQuality: FilterQuality.none),
        ),
      );
}
