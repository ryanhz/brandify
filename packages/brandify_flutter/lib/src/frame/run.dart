import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ads_adapter.dart';
import 'job.dart';

const _jobPath = String.fromEnvironment('BRANDIFY_FRAME_JOB');

/// Entry point of the widget test `brandify frame` generates: one test
/// per screenshot in the job.
void brandifyFrameMain() {
  if (_jobPath.isEmpty) {
    test('brandify frame', () {
      fail('Run this through `brandify frame`, which writes the job file.');
    });
    return;
  }
  final job = FrameJob.read(_jobPath);
  // One caption height per device, so every slide gets the same phone.
  late Map<String, CaptionPlan?> captionPlans;
  setUpAll(() async {
    await initializeFraming();
    final font = job.style.font;
    if (font != null) await loadCaptionFont(font);
    captionPlans = planCaptions(job.items, job.style);
  });
  for (final item in job.items) {
    testWidgets('${item.device} ${item.locale} ${item.shot}', (tester) async {
      final image = await decodeCapture(tester, item.raw);
      try {
        await frameCapture(tester, item, job.style, image,
            captions: captionPlans[item.device]);
      } finally {
        image.dispose();
      }
    });
  }
}

Future<void> loadCaptionFont(String path) async {
  final bytes = await File(path).readAsBytes();
  await (FontLoader(FrameStyle.captionFontFamily)
        ..addFont(Future.value(ByteData.sublistView(bytes))))
      .load();
}

Future<ui.Image> decodeCapture(WidgetTester tester, String path) async =>
    (await tester.runAsync(() async {
      final codec = await ui.instantiateImageCodec(await File(path).readAsBytes());
      return (await codec.getNextFrame()).image;
    }))!;
