import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../logger.dart';
import '../png.dart';
import '../process.dart';
import 'device.dart';

class SimulatorInfo {
  SimulatorInfo({
    required this.udid,
    required this.name,
    required this.state,
    required this.runtime,
  });
  final String udid;
  final String name;
  final String state;

  /// e.g. `com.apple.CoreSimulator.SimRuntime.iOS-26-0`.
  final String runtime;

  bool get booted => state == 'Booted';
  bool get isIos => runtime.contains('.iOS-');

  /// Runtime version as comparable numbers: iOS-26-0 -> [26, 0].
  List<int> get runtimeVersion => runtime
      .split('.')
      .last
      .split('-')
      .skip(1)
      .map((s) => int.tryParse(s) ?? 0)
      .toList();
}

/// Parses `xcrun simctl list -j devices available`.
List<SimulatorInfo> parseSimctlDevices(String json) {
  final devices = (jsonDecode(json) as Map<String, Object?>)['devices']
      as Map<String, Object?>;
  return [
    for (final MapEntry(key: runtime, value: list) in devices.entries)
      for (final d in (list as List).cast<Map<String, Object?>>())
        if (d['isAvailable'] != false)
          SimulatorInfo(
            udid: d['udid'] as String,
            name: d['name'] as String,
            state: d['state'] as String? ?? 'Unknown',
            runtime: runtime,
          ),
  ];
}

int _compareVersions(List<int> a, List<int> b) {
  for (var i = 0; i < a.length || i < b.length; i++) {
    final d = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
    if (d != 0) return d;
  }
  return 0;
}

/// Picks the simulator for a config entry: by UDID, or by name (a booted one
/// first, then the newest iOS runtime).
SimulatorInfo resolveSimulator(IosDeviceConfig config, List<SimulatorInfo> all) {
  if (config.udid != null) {
    for (final s in all) {
      if (s.udid == config.udid) return s;
    }
    throw BrandifyException(
        'No available simulator with UDID ${config.udid} (device "${config.id}").');
  }
  final matches =
      all.where((s) => s.isIos && s.name == config.simulator).toList()
        ..sort((a, b) {
          if (a.booted != b.booted) return a.booted ? -1 : 1;
          return _compareVersions(b.runtimeVersion, a.runtimeVersion);
        });
  if (matches.isEmpty) {
    final names = all.where((s) => s.isIos).map((s) => s.name).toSet().toList()..sort();
    throw BrandifyException(
        'No available iOS simulator named "${config.simulator}" (device "${config.id}"). '
        'Simulator names change with Xcode releases. Available: ${names.join(', ')}.');
  }
  return matches.first;
}

class IosDriver implements DeviceDriver {
  IosDriver(this.config,
      {required this.runner,
      required this.logger,
      this.bootTimeout = const Duration(minutes: 5),
      bool? isMacOS})
      : isMacOS = isMacOS ?? Platform.isMacOS;

  @override
  final IosDeviceConfig config;
  final ProcessRunner runner;
  final Logger logger;
  final Duration bootTimeout;
  final bool isMacOS;

  Future<CommandResult> _simctl(List<String> args,
          {Duration timeout = const Duration(seconds: 60)}) =>
      runner.checked('xcrun', ['simctl', ...args], timeout: timeout);

  @override
  Future<IosSession> prepare({required int port}) async {
    if (!isMacOS) {
      throw BrandifyException(
          'Device "${config.id}" is an iOS simulator, which needs macOS with Xcode. '
          'Use --device to pick only Android devices on this machine.');
    }
    final list = await _simctl(['list', '-j', 'devices', 'available']);
    final sim = resolveSimulator(config, parseSimctlDevices(list.stdout));
    final bootedByUs = !sim.booted;
    if (bootedByUs) {
      logger.info('[${config.id}] booting ${sim.name} (${sim.udid})');
      await _simctl(['boot', sim.udid]);
    } else {
      logger.info('[${config.id}] reusing booted ${sim.name} (${sim.udid})');
    }
    final session = IosSession._(this, sim, bootedByUs);
    try {
      await _simctl(['bootstatus', sim.udid, '-b'], timeout: bootTimeout);
      // No port forwarding: the simulator shares the Mac's loopback interface.
      await _simctl([
        'status_bar', sim.udid, 'override', //
        '--time', '9:41',
        '--dataNetwork', 'wifi', '--wifiMode', 'active', '--wifiBars', '3',
        '--cellularMode', 'active', '--cellularBars', '4', '--operatorName', '',
        '--batteryState', 'charged', '--batteryLevel', '100',
      ]);
      session._overridden = true;
    } catch (_) {
      await session.teardown();
      rethrow;
    }
    return session;
  }
}

class IosSession implements DeviceSession {
  IosSession._(this._driver, this.simulator, this._bootedByUs);
  final IosDriver _driver;
  final SimulatorInfo simulator;
  final bool _bootedByUs;
  bool _overridden = false;

  @override
  String get flutterDeviceId => simulator.udid;

  @override
  Map<String, Object?> get info => {
        'udid': simulator.udid,
        'model': simulator.name,
        'runtime': simulator.runtime.split('.').last,
      };

  @override
  Future<Uint8List> screenshot() async {
    final dir = await Directory.systemTemp.createTemp('brandify_simctl');
    try {
      final file = p.join(dir.path, 'shot.png');
      await _driver._simctl(
          ['io', simulator.udid, 'screenshot', '--type=png', file]);
      final bytes = await File(file).readAsBytes();
      if (!isPng(bytes)) {
        throw BrandifyException('`simctl io screenshot` did not write a PNG.');
      }
      return bytes;
    } finally {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> teardown() async {
    Future<void> quiet(List<String> args) async {
      try {
        await _driver.runner.run('xcrun', ['simctl', ...args]);
      } catch (_) {}
    }

    if (_overridden) await quiet(['status_bar', simulator.udid, 'clear']);
    if (_bootedByUs) {
      _driver.logger.info('[${_driver.config.id}] shutting down ${simulator.name}');
      await quiet(['shutdown', simulator.udid]);
    }
  }
}
