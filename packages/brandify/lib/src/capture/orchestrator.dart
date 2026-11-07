import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../device/android.dart';
import '../device/device.dart';
import '../device/ios.dart';
import '../logger.dart';
import '../process.dart';
import 'server.dart';
import 'stable.dart';

typedef DriverFactory = DeviceDriver Function(DeviceConfig config);

class CaptureResult {
  CaptureResult(this.deviceId, this.locale, this.outDir, this.shots);
  final String deviceId;
  final String locale;
  final String outDir;
  final List<ShotRecord> shots;
}

/// `brandify capture`: for each device, prepare it once, then for each
/// locale run the user's integration test with `flutter test -d`, serving
/// screenshot requests from the test. Devices are always torn down.
class CaptureOrchestrator {
  CaptureOrchestrator({
    required this.config,
    required this.runner,
    required this.logger,
    DriverFactory? driverFactory,
    this.flutter = 'flutter',
    bool? isMacOS,
  })  : isMacOS = isMacOS ?? Platform.isMacOS,
        driverFactory = driverFactory ?? _defaultDrivers(config, runner, logger);

  final BrandifyConfig config;
  final ProcessRunner runner;
  final Logger logger;
  final DriverFactory driverFactory;
  final String flutter;
  final bool isMacOS;

  static DriverFactory _defaultDrivers(
      BrandifyConfig config, ProcessRunner runner, Logger logger) {
    AndroidSdk? sdk;
    return (d) => switch (d) {
          AndroidDeviceConfig() => AndroidDriver(d,
              runner: runner,
              logger: logger,
              sdk: sdk ??= AndroidSdk.locate(),
              bootTimeout: config.capture.bootTimeout),
          IosDeviceConfig() => IosDriver(d,
              runner: runner, logger: logger, bootTimeout: config.capture.bootTimeout),
        };
  }

  Future<List<CaptureResult>> run({Set<String>? devices, Set<String>? locales}) async {
    final selectedDevices = _select('device', config.devices.map((d) => d.id), devices);
    if ((devices == null || devices.isEmpty) && !isMacOS) {
      // Not asked for explicitly: skip what this machine can't run.
      for (final d in config.devices.where((d) => d.platform == DevicePlatform.ios)) {
        logger.warn('skipping iOS device "${d.id}": iOS simulators need macOS.');
        selectedDevices.remove(d.id);
      }
      if (selectedDevices.isEmpty) {
        throw BrandifyException('No device in brandify.yaml can run on this machine.');
      }
    }
    final selectedLocales = _select('locale', config.locales, locales);
    final testFile = p.join(config.root, config.capture.test);
    if (!File(testFile).existsSync()) {
      throw BrandifyException(
          'Capture test ${config.capture.test} not found in ${config.root} (capture.test).');
    }

    final results = <CaptureResult>[];
    for (final device in config.devices.where((d) => selectedDevices.contains(d.id))) {
      final session = await driverFactory(device).prepare(port: config.capture.port);
      try {
        for (final locale in config.locales.where(selectedLocales.contains)) {
          results.add(await _runOne(device, session, locale));
        }
      } finally {
        await session.teardown();
      }
    }
    return results;
  }

  Set<String> _select(String what, Iterable<String> known, Set<String>? wanted) {
    if (wanted == null || wanted.isEmpty) return known.toSet();
    wanted = {...wanted};
    final unknown = wanted.difference(known.toSet());
    if (unknown.isNotEmpty) {
      throw BrandifyException(
          'Unknown $what ${unknown.join(', ')}. Configured: ${known.join(', ')}.');
    }
    return wanted;
  }

  Future<CaptureResult> _runOne(
      DeviceConfig device, DeviceSession session, String locale) async {
    final tag = '[${device.id} $locale]';
    final outDir = p.join(config.outputDir, device.id, locale);
    // This folder belongs to brandify: start clean so stale shots never leak.
    final dir = Directory(outDir);
    if (p.isWithin(config.outputDir, outDir) && dir.existsSync()) {
      dir.deleteSync(recursive: true);
    }
    dir.createSync(recursive: true);

    final runId = _randomId();
    final cap = config.capture;
    final server = await CaptureServer.start(
      port: cap.port,
      runId: runId,
      outDir: outDir,
      capture: () async {
        final s = await captureStable(session.screenshot,
            maxAttempts: cap.stableMaxAttempts, interval: cap.stableInterval);
        if (!s.stable) {
          logger.warn('$tag screen never stabilised after ${s.attempts} captures; '
              'using the last one. Something on screen is still animating.');
        }
        return CapturedPng(s.png, attempts: s.attempts, stable: s.stable);
      },
      onEvent: (m) => logger.info('$tag $m'),
    );

    final tail = <String>[];
    try {
      logger.info('$tag running ${cap.test} on ${session.flutterDeviceId}');
      final args = [
        'test', cap.test, '-d', session.flutterDeviceId, //
        '--dart-define=BRANDIFY_PORT=${cap.port}',
        '--dart-define=BRANDIFY_RUN=$runId',
        '--dart-define=BRANDIFY_LOCALE=$locale',
        '--dart-define=BRANDIFY_DEVICE=${device.id}',
      ];
      logger.detail('$flutter ${args.join(' ')}');
      final proc = await runner.start(flutter, args, workingDirectory: config.root);
      void line(String l) {
        tail.add(l);
        if (tail.length > 60) tail.removeAt(0);
        logger.detail(l);
      }

      final outDone = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).forEach(line);
      final errDone = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).forEach(line);
      final code = await proc.exitCode.timeout(cap.runTimeout, onTimeout: () {
        proc.kill(ProcessSignal.sigkill);
        throw BrandifyException(
            '$tag `flutter test` did not finish within ${cap.runTimeout.inMinutes} min '
            '(capture.run_timeout_s).\n${_explain(tail)}');
      });
      await Future.wait([outDone, errDone]);

      if (code != 0) {
        throw BrandifyException('$tag `flutter test` failed (exit $code).\n${_explain(tail)}');
      }
      if (!server.helloReceived) {
        throw BrandifyException(
            '$tag the test passed but never contacted brandify. Does ${cap.test} '
            'use brandifyTest() from package:brandify_flutter?');
      }
      if (!server.isDone) {
        throw BrandifyException('$tag the test exited without finishing the brandify session.\n${_explain(tail)}');
      }
      if (server.shots.isEmpty) {
        throw BrandifyException('$tag the test took no screenshots (call shot(\'name\')).');
      }
    } finally {
      await server.close();
    }

    final manifest = {
      'brandify_manifest': 1,
      'device': device.id,
      'platform': device.platform.name,
      'locale': locale,
      'run': runId,
      'captured_at': DateTime.now().toUtc().toIso8601String(),
      'device_info': session.info,
      if (server.view != null) 'view': server.view,
      'shots': [for (final s in server.shots) s.toJson()],
    };
    File(p.join(outDir, 'manifest.json'))
        .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(manifest));
    logger.info('$tag ${server.shots.length} shots -> ${p.relative(outDir)}');
    return CaptureResult(device.id, locale, outDir, server.shots);
  }

  /// The last lines of `flutter test` output, with a hint for failures we
  /// recognise.
  static String _explain(List<String> tail) {
    final text = tail.join('\n');
    final hints = <String>[
      if (text.contains('brandify: cannot reach the host'))
        'Hint: the app could not reach the capture server. On Android this needs '
            '`adb reverse` (brandify sets it up); check nothing else removed it.',
      if (text.contains('No supported devices') || text.contains('No devices found') ||
          text.contains('not found'))
        'Hint: `flutter devices` must list the device. Check it is booted and unlocked.',
      if (text.contains('Gradle task') || text.contains('BUILD FAILED') ||
          text.contains('Xcode build'))
        'Hint: the app failed to build. Run the same `flutter test` command yourself to see the full log.',
    ];
    return [...tail.map((l) => '  | $l'), ...hints].join('\n');
  }

  static String _randomId() {
    final r = Random.secure();
    return List.generate(8, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }
}
