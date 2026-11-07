import 'dart:math' as math;
import 'dart:ui' show Size;

/// Their layout constants (app_deploy_screenshots 1.2.1, `FrameGeometry`),
/// in caption points. Scaled to canvas pixels by [unitFor].
const referenceSize = Size(440, 956); // MarketingFrame.referenceSize default
const topPadPoints = 48.0;
const gapPoints = 28.0; // caption to device
const marginPoints = 24.0; // sides and bottom
const lineGapPoints = 8.0; // between caption lines
const maxDeviceWidth = 0.86; // of the space between the side margins

/// Canvas pixels per caption point on [canvas].
double unitFor(Size canvas) =>
    math.sqrt(canvas.width * canvas.height / (referenceSize.width * referenceSize.height));

/// Where the `caption_top` template puts the device, in canvas pixels: the
/// same arithmetic as their stacked `SlideLayout.captionTop`. Given the same
/// caption height, every slide gets the same device, which the template
/// ensures by padding captions to one height per device.
///
/// The device fits whole between the caption block and a bottom margin of
/// [marginPoints], within [maxDeviceWidth] of the width.
class CaptionTopPlacement {
  CaptionTopPlacement._(this.canvas, this.unit, this.screenWidth, this.screenTop, this.bezel,
      this.aspect);

  factory CaptionTopPlacement.of({
    required Size canvas,
    required int captureWidth,
    required int captureHeight,
    required double dpr,
    required double captionHeight,
    double bezelPoints = 0,
  }) {
    final unit = unitFor(canvas);
    final aspect = captureHeight / captureWidth;
    final k = 2 * bezelPoints / (captureWidth / dpr);
    final topPad = topPadPoints * unit, margin = marginPoints * unit;
    final gap = captionHeight > 0 ? gapPoints * unit : 0.0;
    final availW = canvas.width - 2 * margin;
    final availH = canvas.height - topPad - margin - captionHeight - gap;
    final w = math.min(availW * maxDeviceWidth / (1 + k), availH / (aspect + k));
    final bezel = bezelPoints * w / (captureWidth / dpr);
    return CaptionTopPlacement._(canvas, unit, w, topPad + captionHeight + gap + bezel, bezel, aspect);
  }

  final Size canvas;
  final double unit;

  /// The screen itself, in canvas pixels.
  final double screenWidth;
  final double screenTop;
  final double aspect;

  /// Bezel thickness in canvas pixels (0 without one).
  final double bezel;

  double get screenBottom => screenTop + screenWidth * aspect;

  /// Bottom of the device, bezel included.
  double get deviceBottom => screenBottom + bezel;
}
