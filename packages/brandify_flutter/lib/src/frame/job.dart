import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Color, Size;

/// Keep in sync with `frameJobVersion` in
/// `packages/brandify/lib/src/frame/frame_job.dart`.
const frameJobVersion = 1;

enum FrameDevice { screen, bezel }

/// A named slide design: how caption and device are arranged. Each one is
/// built in `ads_adapter.dart`.
enum FrameTemplate {
  /// Caption at the top, the whole device below it above a bottom margin,
  /// the same size on every slide of a device.
  captionTop('caption_top');

  const FrameTemplate(this.id);

  /// The name used in `brandify.yaml` and the job file.
  final String id;

  static FrameTemplate byId(String id) => values.firstWhere((t) => t.id == id,
      orElse: () => throw StateError('brandify: unknown frame template "$id".'));
}

class FrameCaption {
  const FrameCaption(this.headline, [this.subheadline]);
  final String headline;
  final String? subheadline;
}

/// Look shared by every image in a job.
class FrameStyle {
  const FrameStyle({
    this.template = FrameTemplate.captionTop,
    this.captionArea,
    this.background = const [Color(0xFFF2F2F7)],
    this.device = FrameDevice.screen,
    this.font,
  });

  final FrameTemplate template;

  /// Share of the canvas height from the top to the device, or null to size
  /// it from the tallest caption of each device.
  final double? captionArea;

  /// One colour: solid. Several: a top-to-bottom gradient.
  final List<Color> background;
  final FrameDevice device;

  /// Caption font file, loaded as [captionFontFamily].
  final String? font;

  static const captionFontFamily = 'BrandifyCaption';
}

/// One raw capture and where its framed image goes. Written by the CLI,
/// which has already resolved the store slot ([canvas]) and the device
/// pixel ratio the app reported during capture ([dpr]).
class FrameItem {
  const FrameItem({
    required this.device,
    required this.locale,
    required this.shot,
    required this.ios,
    required this.raw,
    required this.out,
    required this.width,
    required this.height,
    required this.dpr,
    required this.slot,
    required this.canvas,
    this.caption,
  });

  final String device;
  final String locale;
  final String shot;
  final bool ios;
  final String raw;
  final String out;

  /// Capture size in physical pixels.
  final int width;
  final int height;
  final double dpr;
  final String slot;

  /// Output size in pixels, from the store slot.
  final Size canvas;
  final FrameCaption? caption;

  bool get tablet => slot.contains('ipad') || slot.contains('tablet');
}

class FrameJob {
  const FrameJob(this.style, this.items);
  final FrameStyle style;
  final List<FrameItem> items;

  static FrameJob read(String path) {
    final json = jsonDecode(File(path).readAsStringSync()) as Map<String, Object?>;
    return FrameJob.fromJson(json);
  }

  static FrameJob fromJson(Map<String, Object?> json) {
    final v = json['brandify_frame_job'];
    if (v != frameJobVersion) {
      throw StateError('brandify: frame job v$v, but brandify_flutter reads v$frameJobVersion. '
          'Use matching versions of brandify and brandify_flutter.');
    }
    final s = json['style'] as Map<String, Object?>;
    final style = FrameStyle(
      template: FrameTemplate.byId(s['template'] as String),
      captionArea: (s['caption_area'] as num?)?.toDouble(),
      background: [for (final c in s['background'] as List) Color(c as int)],
      device: FrameDevice.values.byName(s['device'] as String),
      font: s['font'] as String?,
    );
    return FrameJob(style, [
      for (final i in (json['items'] as List).cast<Map<String, Object?>>())
        FrameItem(
          device: i['device'] as String,
          locale: i['locale'] as String,
          shot: i['shot'] as String,
          ios: i['platform'] == 'ios',
          raw: i['raw'] as String,
          out: i['out'] as String,
          width: i['width'] as int,
          height: i['height'] as int,
          dpr: (i['dpr'] as num).toDouble(),
          slot: i['slot'] as String,
          canvas: () {
            final c = i['canvas'] as Map<String, Object?>;
            return Size((c['width'] as int).toDouble(), (c['height'] as int).toDouble());
          }(),
          caption: switch (i['caption']) {
            final Map<String, Object?> c =>
              FrameCaption(c['headline'] as String, c['subheadline'] as String?),
            _ => null,
          },
        ),
    ]);
  }
}
