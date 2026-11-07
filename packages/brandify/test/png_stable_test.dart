import 'dart:typed_data';

import 'package:brandify/src/capture/stable.dart';
import 'package:brandify/src/png.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

Uint8List png(int shade, {int level = 6}) {
  final i = img.Image(width: 4, height: 3)..clear(img.ColorRgb8(shade, shade, shade));
  return img.encodePng(i, level: level);
}

void main() {
  test('pngSize reads IHDR', () {
    expect(pngSize(png(0)), (width: 4, height: 3));
    expect(pngSize([1, 2, 3]), isNull);
  });

  test('samePixels: byte-equal, re-encoded, different', () {
    expect(samePixels(png(10), png(10)), isTrue);
    final a = png(10, level: 0), b = png(10, level: 9);
    expect(sameBytes(a, b), isFalse, reason: 'different compression');
    expect(samePixels(a, b), isTrue);
    expect(samePixels(png(10), png(11)), isFalse);
  });

  test('captureStable stops at the first repeated frame', () async {
    final frames = [png(1), png(2), png(3), png(3), png(4)];
    var i = 0;
    final s = await captureStable(() async => frames[i++], interval: Duration.zero);
    expect(s.attempts, 4);
    expect(s.stable, isTrue);
  });

  test('captureStable gives up after maxAttempts and returns the last frame', () async {
    var i = 0;
    final s = await captureStable(() async => png(i++),
        maxAttempts: 3, interval: Duration.zero);
    expect(s.attempts, 3);
    expect(s.stable, isFalse);
    expect(samePixels(s.png, png(2)), isTrue);
  });
}
