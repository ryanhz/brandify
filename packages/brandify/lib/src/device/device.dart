import 'dart:typed_data';

import '../config.dart';

/// Gets one configured device ready for capture.
abstract class DeviceDriver {
  DeviceConfig get config;

  /// Boots or attaches to the device, cleans the status bar and makes the
  /// host's capture server reachable on [port] from inside the app.
  Future<DeviceSession> prepare({required int port});
}

/// A device that is ready. Always call [teardown], also after failures.
abstract class DeviceSession {
  /// What `flutter test -d` takes.
  String get flutterDeviceId;

  /// Facts for the manifest (OS version, model, screen size...).
  Map<String, Object?> get info;

  /// One raw PNG of the whole screen, system bars included.
  Future<Uint8List> screenshot();

  /// Undo what [DeviceDriver.prepare] changed, and shut down what it booted.
  Future<void> teardown();
}
