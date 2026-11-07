import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'device/android.dart';
import 'device/ios.dart';
import 'process.dart';

enum CheckStatus {
  ok('✓'),
  warn('!'),
  fail('✗'),

  /// Optional tool missing, or a check that doesn't apply here.
  skip('-');

  const CheckStatus(this.mark);
  final String mark;
}

class Check {
  Check(this.status, this.title, {this.hint});
  final CheckStatus status;
  final String title;

  /// What to do about it, printed indented below.
  final String? hint;
}

/// Oldest Flutter that `brandify_flutter` supports (app_deploy_screenshots'
/// floor).
const minFlutter = [3, 35, 3];

/// `brandify doctor`: checks what a capture needs, for the devices in
/// `brandify.yaml` (or for both platforms when there is no config yet).
/// Only reads: it never boots a device or changes a file.
class Doctor {
  Doctor({
    required this.configPath,
    required this.runner,
    this.flutter = 'flutter',
    bool? isMacOS,
    Map<String, String>? env,
  })  : isMacOS = isMacOS ?? Platform.isMacOS,
        env = env ?? Platform.environment;

  final String configPath;
  final ProcessRunner runner;
  final String flutter;
  final bool isMacOS;
  final Map<String, String> env;

  String get _root => p.dirname(p.absolute(configPath));

  Future<List<Check>> run() async {
    final checks = <Check>[await _flutter(), ..._project()];
    final config = _config(checks);
    final android = config?.devices.whereType<AndroidDeviceConfig>().toList();
    final ios = config?.devices.whereType<IosDeviceConfig>().toList();

    if (android == null || android.isNotEmpty) checks.addAll(await _android(android ?? const []));
    if (ios == null || ios.isNotEmpty) checks.addAll(await _ios(ios ?? const []));
    checks.add(await _fastlane());
    return checks;
  }

  /// Runs a tool; null when it can't be started at all.
  Future<CommandResult?> _try(String exe, List<String> args,
      {Duration timeout = const Duration(seconds: 60)}) async {
    try {
      return await runner.run(exe, args, timeout: timeout);
    } on BrandifyException {
      return null;
    }
  }

  // -- Flutter and the project ----------------------------------------------

  Future<Check> _flutter() async {
    final r = await _try(flutter, ['--version', '--machine'], timeout: const Duration(minutes: 2));
    if (r == null || r.exitCode != 0) {
      return Check(CheckStatus.fail, 'Flutter not found', hint: 'Install Flutter and put `flutter` on PATH.');
    }
    String? version, dart;
    final out = r.stdout;
    final start = out.indexOf('{');
    try {
      final j = jsonDecode(out.substring(start)) as Map<String, Object?>;
      version = j['frameworkVersion'] as String?;
      dart = (j['dartSdkVersion'] as String?)?.split(' ').first;
    } catch (_) {}
    if (version == null) {
      return Check(CheckStatus.warn, 'Flutter found, version unknown',
          hint: '`flutter --version --machine` printed no frameworkVersion.');
    }
    final title = 'Flutter $version${dart == null ? '' : ' (Dart $dart)'}';
    if (compareVersions(version, minFlutter) < 0) {
      return Check(CheckStatus.fail, title,
          hint: 'brandify needs Flutter ${minFlutter.join('.')} or newer: `flutter upgrade`.');
    }
    return Check(CheckStatus.ok, title);
  }

  List<Check> _project() {
    final pubspec = File(p.join(_root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      return [
        Check(CheckStatus.fail, 'No pubspec.yaml in $_root',
            hint: 'Run brandify in your Flutter app\'s folder (or pass --config).')
      ];
    }
    final YamlMap? y;
    try {
      y = loadYaml(pubspec.readAsStringSync()) as YamlMap?;
    } catch (e) {
      return [Check(CheckStatus.fail, 'pubspec.yaml does not parse', hint: '$e')];
    }
    bool has(String section, String dep) => (y?[section] as YamlMap?)?.containsKey(dep) ?? false;
    final name = y?['name'];
    if (has('dependencies', 'brandify_flutter') || has('dev_dependencies', 'brandify_flutter')) {
      return [Check(CheckStatus.ok, '$name depends on brandify_flutter')];
    }
    return [
      Check(CheckStatus.fail, '$name does not depend on brandify_flutter',
          hint: 'The capture test needs it: `flutter pub add dev:brandify_flutter`.')
    ];
  }

  BrandifyConfig? _config(List<Check> checks) {
    final rel = p.relative(configPath);
    if (!File(configPath).existsSync()) {
      checks.add(Check(CheckStatus.fail, 'No $rel',
          hint: 'Create it with `dart run brandify init`. Checking both platforms meanwhile.'));
      return null;
    }
    final BrandifyConfig c;
    try {
      c = BrandifyConfig.load(configPath);
    } on BrandifyException catch (e) {
      checks.add(Check(CheckStatus.fail, '$rel is invalid', hint: e.message));
      return null;
    }
    checks.add(Check(CheckStatus.ok,
        '$rel: ${c.locales.length} locale${c.locales.length == 1 ? '' : 's'} (${c.locales.join(', ')}), '
        '${c.devices.length} device${c.devices.length == 1 ? '' : 's'} (${c.devices.map((d) => d.id).join(', ')})'));
    final test = File(p.join(c.root, c.capture.test));
    checks.add(test.existsSync()
        ? Check(CheckStatus.ok, 'Capture test ${c.capture.test}')
        : Check(CheckStatus.fail, 'Capture test ${c.capture.test} not found',
            hint: 'Create it (`dart run brandify init` writes one) or set capture.test.'));
    return c;
  }

  // -- Android ---------------------------------------------------------------

  Future<List<Check>> _android(List<AndroidDeviceConfig> devices) async {
    final sdk = AndroidSdk.locate(env);
    final adb = await _try(sdk.adb, ['version']);
    if (adb == null || adb.exitCode != 0) {
      return [
        Check(devices.isEmpty ? CheckStatus.warn : CheckStatus.fail, 'Android: adb not found',
            hint: 'Install the Android SDK platform-tools and set ANDROID_HOME (or put adb on PATH).')
      ];
    }
    final checks = [
      Check(CheckStatus.ok, 'Android: ${LineSplitter.split(adb.stdout).first.trim()} (${sdk.adb})')
    ];

    final avds = devices.where((d) => d.avd != null).toList();
    final list = await _try(sdk.emulator, ['-list-avds']);
    if (list == null || list.exitCode != 0) {
      checks.add(Check(avds.isEmpty ? CheckStatus.warn : CheckStatus.fail, 'Android: emulator not found',
          hint: 'Install the Android Emulator (sdkmanager "emulator") and set ANDROID_HOME.'));
    } else {
      final names = parseAvdList(list.stdout);
      if (devices.isEmpty) {
        checks.add(names.isEmpty
            ? Check(CheckStatus.warn, 'Android: no AVDs', hint: 'Create one in Android Studio\'s Device Manager.')
            : Check(CheckStatus.ok, 'Android: AVDs ${names.join(', ')}'));
      }
      for (final d in avds) {
        checks.add(names.contains(d.avd)
            ? Check(CheckStatus.ok, '[${d.id}] AVD ${d.avd}')
            : Check(CheckStatus.fail, '[${d.id}] no AVD named "${d.avd}"',
                hint: names.isEmpty
                    ? 'No AVDs exist; create one in Android Studio\'s Device Manager.'
                    : 'Available: ${names.join(', ')}.'));
      }
    }

    final serials = devices.where((d) => d.serial != null).toList();
    if (serials.isNotEmpty) {
      final r = await _try(sdk.adb, ['devices']);
      final connected = r == null ? <String>{} : parseAdbDevices(r.stdout);
      for (final d in serials) {
        checks.add(connected.contains(d.serial)
            ? Check(CheckStatus.ok, '[${d.id}] ${d.serial} connected')
            : Check(CheckStatus.warn, '[${d.id}] ${d.serial} not connected',
                hint: 'It must be connected (state `device` in `adb devices`) when you capture.'));
      }
    }
    return checks;
  }

  // -- iOS -------------------------------------------------------------------

  Future<List<Check>> _ios(List<IosDeviceConfig> devices) async {
    if (!isMacOS) {
      return [
        Check(devices.isEmpty ? CheckStatus.skip : CheckStatus.warn, 'iOS: needs macOS',
            hint: devices.isEmpty
                ? null
                : 'capture skips ${devices.map((d) => d.id).join(', ')} on this machine.')
      ];
    }
    final xcode = await _try('xcodebuild', ['-version']);
    if (xcode == null || xcode.exitCode != 0) {
      return [
        Check(devices.isEmpty ? CheckStatus.warn : CheckStatus.fail, 'iOS: Xcode not found',
            hint: 'Install Xcode, then `sudo xcode-select -s /Applications/Xcode.app` and open it once.')
      ];
    }
    final checks = [Check(CheckStatus.ok, 'iOS: ${LineSplitter.split(xcode.stdout).first.trim()}')];

    final r = await _try('xcrun', ['simctl', 'list', '-j', 'devices', 'available']);
    List<SimulatorInfo>? sims;
    try {
      if (r != null && r.exitCode == 0) sims = parseSimctlDevices(r.stdout);
    } catch (_) {}
    if (sims == null) {
      checks.add(Check(CheckStatus.fail, 'iOS: `xcrun simctl list` failed',
          hint: r == null ? null : (r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim())));
      return checks;
    }
    if (!sims.any((s) => s.isIos)) {
      checks.add(Check(devices.isEmpty ? CheckStatus.warn : CheckStatus.fail, 'iOS: no iOS simulator runtime',
          hint: 'Install one in Xcode > Settings > Components.'));
      return checks;
    }
    for (final d in devices) {
      try {
        final s = resolveSimulator(d, sims);
        final runtime = s.runtime.split('.').last.replaceFirst('-', ' ').replaceAll('-', '.');
        checks.add(Check(CheckStatus.ok, '[${d.id}] ${s.name} ($runtime)'));
      } on BrandifyException catch (e) {
        checks.add(Check(CheckStatus.fail, '[${d.id}] simulator not found', hint: e.message));
      }
    }
    return checks;
  }

  // -- fastlane (optional) ---------------------------------------------------

  Future<Check> _fastlane() async {
    final r = await _try('fastlane', ['--version']);
    final version = r == null ? null : RegExp(r'fastlane (\d+\.\d+\.\d+)').firstMatch(r.stdout)?.group(1);
    if (r == null || r.exitCode != 0 || version == null) {
      return Check(CheckStatus.skip, 'fastlane not found (optional)',
          hint: 'Only needed to upload what `brandify export` writes (supply, deliver).');
    }
    return Check(CheckStatus.ok, 'fastlane $version');
  }
}

/// AVD names from `emulator -list-avds` (which can mix in `INFO |` lines).
List<String> parseAvdList(String out) => [
      for (final l in LineSplitter.split(out))
        if (l.trim().isNotEmpty && !l.contains('|') && !l.contains(' ')) l.trim()
    ];

/// Serials in the `device` state, from `adb devices`.
Set<String> parseAdbDevices(String out) => {
      for (final l in LineSplitter.split(out).skip(1))
        if (l.split(RegExp(r'\s+')) case [final serial, 'device', ...]) serial
    };

/// Compares a version string like `3.38.0-0.1.pre` to [min] by its leading
/// numbers.
int compareVersions(String version, List<int> min) {
  final parts = RegExp(r'^\d+(\.\d+)*').stringMatch(version)?.split('.').map(int.parse).toList() ?? [];
  for (var i = 0; i < min.length; i++) {
    final v = i < parts.length ? parts[i] : 0;
    if (v != min[i]) return v - min[i];
  }
  return 0;
}
