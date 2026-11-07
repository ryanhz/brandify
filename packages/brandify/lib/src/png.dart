import 'dart:typed_data';

import 'package:image/image.dart' as img;

const _signature = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

bool isPng(List<int> bytes) {
  if (bytes.length < 24) return false;
  for (var i = 0; i < 8; i++) {
    if (bytes[i] != _signature[i]) return false;
  }
  return true;
}

/// Width and height from the IHDR chunk, without decoding the image.
({int width, int height})? pngSize(List<int> bytes) {
  if (!isPng(bytes)) return null;
  int u32(int o) =>
      (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3];
  return (width: u32(16), height: u32(20));
}

bool sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// True if two PNGs show the same pixels. Byte equality is the fast path
/// (`adb screencap` and, on the Xcode version tested, `simctl io screenshot`
/// encode identical pixels identically). Decoding is the fallback in case a
/// tool writes varying metadata.
bool samePixels(Uint8List a, Uint8List b) {
  if (sameBytes(a, b)) return true;
  final sa = pngSize(a), sb = pngSize(b);
  if (sa == null || sb == null || sa != sb) return false;
  final ia = img.decodePng(a), ib = img.decodePng(b);
  if (ia == null || ib == null) return false;
  return sameBytes(ia.getBytes(order: img.ChannelOrder.rgba),
      ib.getBytes(order: img.ChannelOrder.rgba));
}

/// True if the PNG can carry transparency: an alpha channel (colour types 4
/// and 6) or a `tRNS` chunk. Both stores reject such screenshots.
bool pngHasAlpha(List<int> bytes) {
  if (!isPng(bytes)) return false;
  final colorType = bytes[25];
  if (colorType == 4 || colorType == 6) return true;
  var o = 8;
  while (o + 8 <= bytes.length) {
    final len = (bytes[o] << 24) | (bytes[o + 1] << 16) | (bytes[o + 2] << 8) | bytes[o + 3];
    final type = String.fromCharCodes(bytes.sublist(o + 4, o + 8));
    if (type == 'tRNS') return true;
    if (type == 'IDAT' || type == 'IEND') return false;
    o += 12 + len;
  }
  return false;
}

/// [bytes] re-encoded without an alpha channel, if every pixel is opaque;
/// null if any pixel is (partly) transparent.
Uint8List? flattenOpaquePng(Uint8List bytes) {
  final image = img.decodePng(bytes);
  if (image == null) return null;
  for (final px in image) {
    if (px.a < px.maxChannelValue) return null;
  }
  return img.encodePng(image.convert(numChannels: 3));
}
