import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../logger.dart';
import '../png.dart';
import '../process.dart';
import 'device.dart';

/// Paths to `adb` and `emulator`: from `$ANDROID_HOME` / `$ANDROID_SDK_ROOT`
/// when set, otherwise whatever is on PATH.
class AndroidSdk {
  AndroidSdk({required this.adb, required this.emulator});
  final String adb;
  final String emulator;

  factory AndroidSdk.locate([Map<String, String>? env]) {
    env ??= Platform.environment;
    final exe = Platform.isWindows ? '.exe' : '';
    for (final key in ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
      final home = env[key];
      if (home == null || home.isEmpty) continue;
      final adb = p.join(home, 'platform-tools', 'adb$exe');
      final emu = p.join(home, 'emulator', 'emulator$exe');
      if (File(adb).existsSync()) {
        return AndroidSdk(
            adb: adb, emulator: File(emu).existsSync() ? emu : 'emulator');
      }
    }
    return AndroidSdk(adb: 'adb', emulator: 'emulator');
  }
}

class AndroidDriver implements DeviceDriver {
  AndroidDriver(this.config,
      {required this.runner,
      required this.logger,
      required this.sdk,
      this.bootTimeout = const Duration(minutes: 5),
      this.pollInterval = const Duration(seconds: 2),
      this.quietInterval = const Duration(seconds: 1),
      this.quietTimeout = const Duration(seconds: 90)});

  @override
  final AndroidDeviceConfig config;
  final ProcessRunner runner;
  final Logger logger;
  final AndroidSdk sdk;
  final Duration bootTimeout;
  final Duration pollInterval;
  final Duration quietInterval;
  final Duration quietTimeout;

  Future<CommandResult> _adb(List<String> args,
          {Duration timeout = const Duration(seconds: 60)}) =>
      runner.checked(sdk.adb, args, timeout: timeout);

  /// Serials of devices in the `device` state.
  Future<List<String>> connectedSerials() async {
    final r = await _adb(['devices']);
    return LineSplitter.split(r.stdout)
        .skip(1)
        .map((l) => l.trim().split(RegExp(r'\s+')))
        .where((f) => f.length >= 2 && f[1] == 'device')
        .map((f) => f[0])
        .toList();
  }

  Future<String?> _runningEmulatorFor(String avd, List<String> serials) async {
    for (final s in serials.where((s) => s.startsWith('emulator-'))) {
      final r = await runner.run(sdk.adb, ['-s', s, 'emu', 'avd', 'name'],
          timeout: const Duration(seconds: 15));
      if (r.exitCode == 0 &&
          LineSplitter.split(r.stdout).firstOrNull?.trim() == avd) {
        return s;
      }
    }
    return null;
  }

  @override
  Future<AndroidSession> prepare({required int port}) async {
    final serials = await connectedSerials();
    String serial;
    Process? booted;
    if (config.serial != null) {
      serial = config.serial!;
      if (!serials.contains(serial)) {
        throw BrandifyException(
            'Android device "$serial" (device "${config.id}") is not connected. '
            'Connected: ${serials.isEmpty ? 'none' : serials.join(', ')}.');
      }
    } else {
      final running = await _runningEmulatorFor(config.avd!, serials);
      if (running != null) {
        logger.info('[${config.id}] reusing running emulator $running (${config.avd})');
        serial = running;
      } else {
        final emuPort = _freeEmulatorPort(serials);
        serial = 'emulator-$emuPort';
        logger.info('[${config.id}] booting AVD ${config.avd} as $serial');
        booted = await _boot(config.avd!, emuPort);
      }
    }
    final session = AndroidSession._(this, serial, booted);
    try {
      await session._waitForBoot();
      await session._setUp(port);
    } catch (_) {
      await session.teardown();
      rethrow;
    }
    return session;
  }

  int _freeEmulatorPort(List<String> serials) {
    final used = serials
        .where((s) => s.startsWith('emulator-'))
        .map((s) => int.tryParse(s.substring(9)))
        .whereType<int>()
        .toSet();
    for (var port = 5554; port <= 5682; port += 2) {
      if (!used.contains(port) && !used.contains(port + 1)) return port;
    }
    throw BrandifyException('No free emulator console port (5554–5682).');
  }

  Future<Process> _boot(String avd, int port) async {
    final proc = await runner.start(sdk.emulator, [
      '-avd', avd, '-port', '$port', //
      '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot-save',
      ...config.emulatorArgs,
    ]);
    return proc;
  }
}

class AndroidSession implements DeviceSession {
  AndroidSession._(this._driver, this.serial, this._emulator) {
    final emu = _emulator;
    if (emu != null) {
      // Drain output so the emulator never blocks on a full pipe; keep the
      // tail for error messages.
      void keep(String l) {
        _emulatorLog.add(l);
        if (_emulatorLog.length > 40) _emulatorLog.removeAt(0);
        _driver.logger.detail('[emulator] $l');
      }

      emu.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(keep);
      emu.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(keep);
      emu.exitCode.then((c) => _emulatorExit = c);
    }
  }

  final AndroidDriver _driver;
  final String serial;
  final Process? _emulator;
  final _emulatorLog = <String>[];
  int? _emulatorExit;
  int? _reversedPort;
  bool _demo = false;
  final _info = <String, Object?>{};

  @override
  String get flutterDeviceId => serial;
  @override
  Map<String, Object?> get info => {'serial': serial, ..._info};

  Future<CommandResult> _adb(List<String> args,
          {Duration timeout = const Duration(seconds: 60)}) =>
      _driver._adb(['-s', serial, ...args], timeout: timeout);

  Future<String> _shell(List<String> args) async =>
      (await _adb(['shell', ...args])).stdout.trim();

  Future<void> _waitForBoot() async {
    final deadline = DateTime.now().add(_driver.bootTimeout);
    while (true) {
      if (_emulatorExit != null) {
        throw BrandifyException(
            'The emulator for AVD "${_driver.config.avd}" exited (code $_emulatorExit) before booting:\n'
            '${_emulatorLog.join('\n')}');
      }
      final r = await _driver.runner.run(_driver.sdk.adb,
          ['-s', serial, 'shell', 'getprop', 'sys.boot_completed'],
          timeout: const Duration(seconds: 15));
      if (r.exitCode == 0 && r.stdout.trim() == '1') return;
      if (DateTime.now().isAfter(deadline)) {
        throw BrandifyException(
            '$serial did not finish booting within ${_driver.bootTimeout.inSeconds} s '
            '(capture.boot_timeout_s).');
      }
      await Future<void>.delayed(_driver.pollInterval);
    }
  }

  Future<void> _demoCommand(String command, [Map<String, String> extras = const {}]) async {
    final r = await _shell([
      'am', 'broadcast', '-a', 'com.android.systemui.demo', '-e', 'command', command,
      for (final e in extras.entries) ...['-e', e.key, e.value],
    ]);
    if (!r.contains('Broadcast completed')) {
      throw BrandifyException('Demo-mode command "$command" was not delivered on $serial:\n$r');
    }
  }

  Future<void> _setUp(int port) async {
    final log = _driver.logger;
    _info['api'] = int.tryParse(await _shell(['getprop', 'ro.build.version.sdk']));
    _info['model'] = await _shell(['getprop', 'ro.product.model']);
    _info['screen'] = (await _shell(['wm', 'size'])).split('\n').last.split(': ').last;
    log.detail('$serial: API ${_info['api']}, ${_info['model']}, ${_info['screen']}');

    // `sys.boot_completed` comes before System UI has finished setting up.
    // Entering demo mode then (API 36, cold boot) left a second Wi-Fi icon
    // that stays for the whole session. Waiting until the screen is quiet
    // fixed it in every cold boot tried.
    await _waitForQuietScreen();

    // Clean status bar via System UI demo mode.
    await _shell(['settings', 'put', 'global', 'sysui_demo_allowed', '1']);
    if (await _shell(['settings', 'get', 'global', 'sysui_demo_allowed']) != '1') {
      throw BrandifyException(
          'Could not enable System UI demo mode on $serial; the status bar would not be clean.');
    }
    _demo = true;
    await _demoCommand('enter');
    await _demoCommand('clock', {'hhmm': '0941'});
    await _demoCommand('battery', {'level': '100', 'plugged': 'false', 'powersave': 'false'});
    await _demoCommand('network', {'wifi': 'show', 'level': '4', 'fully': 'true'});
    // `datatype none|lte|5g` is ignored on API 36 (it always draws "3G").
    // Hiding the mobile signal entirely is the clean, API-independent option.
    await _demoCommand('network', {'mobile': 'hide'});
    await _demoCommand('network', {'airplane': 'hide'});
    await _demoCommand('notifications', {'visible': 'false'});
    await _demoCommand('status', {
      'bluetooth': 'hide', 'location': 'hide', 'alarm': 'hide', //
      'volume': 'hide', 'zen': 'hide', 'mute': 'hide', 'speakerphone': 'hide',
    });

    // Let the app reach the host's capture server on 127.0.0.1:port.
    await _adb(['reverse', 'tcp:$port', 'tcp:$port']);
    _reversedPort = port;
  }

  /// Waits until three consecutive screenshots, [AndroidDriver.quietInterval]
  /// apart, are identical.
  Future<void> _waitForQuietScreen() async {
    // Printed without --verbose too: it's a silent wait otherwise.
    _driver.logger.info('[${_driver.config.id}] waiting for system UI to settle before cleaning '
        'the status bar (about 14 s after a cold boot)');
    final sw = Stopwatch()..start();
    Uint8List? previous;
    var same = 0;
    while (sw.elapsed < _driver.quietTimeout) {
      final current = await screenshot();
      same = previous != null && sameBytes(previous, current) ? same + 1 : 0;
      if (same >= 2) {
        _driver.logger.info('[${_driver.config.id}] system UI settled after ${sw.elapsed.inSeconds} s');
        return;
      }
      previous = current;
      await Future<void>.delayed(_driver.quietInterval);
    }
    _driver.logger.warn('$serial: the screen kept changing for ${_driver.quietTimeout.inSeconds} s '
        'after boot; applying the clean status bar anyway. Check the status bar in the results.');
  }

  @override
  Future<Uint8List> screenshot() async {
    final r = await _adb(['exec-out', 'screencap', '-p'],
        timeout: const Duration(seconds: 30));
    if (!isPng(r.stdoutBytes)) {
      throw BrandifyException('`adb exec-out screencap -p` on $serial did not return a PNG.');
    }
    return Uint8List.fromList(r.stdoutBytes);
  }

  @override
  Future<void> teardown() async {
    final runner = _driver.runner, adb = _driver.sdk.adb;
    Future<void> quiet(List<String> args) async {
      try {
        await runner.run(adb, ['-s', serial, ...args], timeout: const Duration(seconds: 20));
      } catch (_) {}
    }

    if (_reversedPort != null) await quiet(['reverse', '--remove', 'tcp:$_reversedPort']);
    if (_demo && _emulator == null) {
      // Only restore a device we didn't boot; a booted one is shut down anyway.
      await quiet(['shell', 'am', 'broadcast', '-a', 'com.android.systemui.demo', '-e', 'command', 'exit']);
    }
    final emu = _emulator;
    if (emu != null && _emulatorExit == null) {
      _driver.logger.info('[${_driver.config.id}] shutting down $serial');
      await quiet(['emu', 'kill']);
      await emu.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
        emu.kill(ProcessSignal.sigkill);
        return -1;
      });
    }
  }
}
