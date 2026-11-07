import 'dart:typed_data';

import '../png.dart';

class StableShot {
  StableShot(this.png, this.attempts, this.stable);
  final Uint8List png;
  final int attempts;

  /// False when [maxAttempts] ran out before two frames matched. The last
  /// frame is still used.
  final bool stable;
}

/// Captures until two consecutive screenshots show the same pixels.
///
/// Needed because system UI (gesture pill, demo-mode icons, keyboard) keeps
/// animating after Flutter has settled.
Future<StableShot> captureStable(
  Future<Uint8List> Function() grab, {
  int maxAttempts = 10,
  Duration interval = const Duration(milliseconds: 300),
}) async {
  Uint8List? previous;
  for (var attempt = 1;; attempt++) {
    final current = await grab();
    if (previous != null && samePixels(previous, current)) {
      return StableShot(current, attempt, true);
    }
    if (attempt >= maxAttempts) return StableShot(current, attempt, false);
    previous = current;
    await Future<void>.delayed(interval);
  }
}
