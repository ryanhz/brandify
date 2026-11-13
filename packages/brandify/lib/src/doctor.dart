import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'device/android.dart';
import 'device/ios.dart';
import 'frame/frame_job.dart';
import 'icons/icon_generator.dart';
import 'logger.dart';
import 'metadata/metadata_writer.dart';
import 'process.dart';
import 'store/slots.dart';

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
    this.devices = const {},
    this.flutter = 'flutter',
    bool? isMacOS,
    Map<String, String>? env,
  })  : isMacOS = isMacOS ?? Platform.isMacOS,
        env = env ?? Platform.environment;

  final String configPath;
  final ProcessRunner runner;

  /// Only these device ids, as `capture -d`. When empty, like capture, a
  /// device this machine can't run (iOS off macOS, Android without adb) is
  /// a warning: capture skips it.
  final Set<String> devices;
  final String flutter;
  final bool isMacOS;
  final Map<String, String> env;

  String get _root => p.dirname(p.absolute(configPath));

  Future<List<Check>> run() async {
    _skipped.clear();
    final checks = <Check>[await _flutter(), ..._project()];
    final config = _config(checks);
    if (config != null) checks.addAll(await _secrets(config));
    final selected = config == null ? null : _select(config, checks);
    final android = selected?.whereType<AndroidDeviceConfig>().toList();
    final ios = selected?.whereType<IosDeviceConfig>().toList();

    if (android == null || android.isNotEmpty) checks.addAll(await _android(android ?? const []));
    if (ios == null || ios.isNotEmpty) checks.addAll(await _ios(ios ?? const []));
    if (selected != null && selected.isNotEmpty && _skipped.length == selected.length) {
      checks.add(Check(CheckStatus.fail, 'No configured device can run on this machine',
          hint: 'capture would skip ${_skipped.join(', ')}.'));
    }
    checks.add(await _fastlane());
    return checks;
  }

  /// Devices capture would skip on this machine (only when no [devices]).
  final _skipped = <String>[];

  /// A device this machine can't run: a warning that capture skips it, or a
  /// failure when it was asked for with `-d`.
  Check _unavailable(String title, List<DeviceConfig> devices, {required String fix}) {
    if (devices.isEmpty) return Check(CheckStatus.warn, title, hint: fix);
    if (this.devices.isNotEmpty) return Check(CheckStatus.fail, title, hint: fix);
    _skipped.addAll(devices.map((d) => d.id));
    return Check(CheckStatus.warn, title,
        hint: 'capture skips ${devices.map((d) => d.id).join(', ')} on this machine. $fix');
  }

  List<DeviceConfig> _select(BrandifyConfig config, List<Check> checks) {
    if (devices.isEmpty) return config.devices;
    final known = config.devices.map((d) => d.id).toSet();
    final unknown = devices.difference(known);
    if (unknown.isNotEmpty) {
      checks.add(Check(CheckStatus.fail, 'Unknown device ${unknown.join(', ')}',
          hint: 'Configured: ${known.join(', ')}.'));
    }
    return config.devices.where((d) => devices.contains(d.id)).toList();
  }

  /// Runs a tool; null when it can't be started at all.
  Future<CommandResult?> _try(String exe, List<String> args,
      {Duration timeout = const Duration(seconds: 60), String? workingDirectory}) async {
    try {
      return await runner.run(exe, args, timeout: timeout, workingDirectory: workingDirectory);
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
    checks.addAll(_app(c));
    return c;
  }

  /// `app:` and `metadata:`: only `rename`, `icons` and `metadata` need them,
  /// so gaps are warnings; capture doesn't care.
  List<Check> _app(BrandifyConfig c) {
    final checks = <Check>[];
    final app = c.app;
    const ids = ['name', 'android_package', 'ios_bundle_id'];
    final missing = app.missing(ids);
    if (missing.length == ids.length && app.logoPath == null) {
      checks.add(Check(CheckStatus.skip, 'app: not filled in',
          hint: 'Only `brandify rename` and `brandify icons` need it.'));
    } else if (missing.isNotEmpty) {
      checks.add(Check(CheckStatus.warn, 'app: ${missing.map((k) => 'app.$k').join(', ')} not filled in',
          hint: '`brandify rename` needs name, android_package and ios_bundle_id.'));
    } else {
      checks.add(Check(CheckStatus.ok,
          'app: "${app.name}" (Android ${app.androidPackage}, iOS ${app.iosBundleId})'));
    }
    if (app.logoPath != null) {
      final icons = IconGenerator(config: c, runner: runner, logger: Logger());
      try {
        final (path: _, :warning) = icons.checkLogo();
        checks.add(!icons.hasDependency()
            ? Check(CheckStatus.warn, 'app.logo_path ${app.logoPath}, but no flutter_launcher_icons',
                hint: '`brandify icons` runs it: `flutter pub add dev:flutter_launcher_icons`.')
            : warning != null
                ? Check(CheckStatus.warn, 'app.logo_path ${app.logoPath}', hint: warning)
                : Check(CheckStatus.ok, 'app.logo_path ${app.logoPath}'));
      } on BrandifyException catch (e) {
        checks.add(Check(CheckStatus.warn, 'app.logo_path is not usable', hint: e.message));
      }
    }
    final writer = MetadataWriter(config: c, logger: Logger(), env: brandifyEnv(c.root, env));
    if (c.metadata.isNotEmpty) {
      // app_store: problems are reported by its own check.
      final problems = writer.validate(stores: Store.values.toSet(), includeAppStore: false);
      checks.add(problems.isEmpty
          ? Check(CheckStatus.ok, 'metadata: ${c.metadata.keys.join(', ')}')
          : Check(CheckStatus.warn, 'metadata: not ready for `brandify metadata`', hint: problems.join('\n')));
    }
    checks.add(_appStore(c, writer));
    if (c.devices.any((d) => d.platform == DevicePlatform.android)) checks.add(_featureGraphic(c));
    return checks;
  }

  /// `app_store:` against what App Store Connect needs before a submission.
  Check _appStore(BrandifyConfig c, MetadataWriter writer) {
    final a = c.appStore;
    final gaps = appStoreGaps(a);
    if (a == null) {
      return Check(CheckStatus.skip, 'app_store: not set',
          hint: 'Before a submission App Store Connect needs a category, copyright, support and privacy '
              'URLs and an App Review contact. Add an `app_store:` block (see the README) and '
              '`brandify metadata` writes them for deliver.');
    }
    final problems = writer.appStoreProblems();
    if (problems.isNotEmpty) {
      return Check(CheckStatus.warn, 'app_store: not ready for `brandify metadata`',
          hint: [
            ...problems,
            if (problems.any((l) => l.contains('not set in the environment')))
              'Set them in the environment or in $dotEnvFile next to brandify.yaml (NAME=value lines).',
          ].join('\n'));
    }
    if (gaps.isNotEmpty) {
      return Check(CheckStatus.warn, 'app_store: ${gaps.length} field${gaps.length == 1 ? '' : 's'} App Store Connect needs '
          'before a submission ${gaps.length == 1 ? 'is' : 'are'} empty',
          hint: gaps.join(', '));
    }
    return Check(CheckStatus.ok, 'app_store: ${a.primaryCategory!.toLowerCase()}, review contact '
        '${a.review['first_name']} ${a.review['last_name']}');
  }

  /// `feature_graphic:`: whether `brandify frame` can make one.
  Check _featureGraphic(BrandifyConfig c) {
    final fg = c.featureGraphic;
    if (fg == null) {
      return Check(CheckStatus.skip, 'feature_graphic: not set (Google Play needs one to publish)',
          hint: 'Add `feature_graphic: {}` to brandify.yaml and `brandify frame` makes the 1024×500 banner '
              'from app.logo_path and each locale\'s metadata name and subtitle.');
    }
    try {
      final items = FrameJob.featureGraphicItems(c, c.locales, Logger());
      final style = FrameJob.resolveFeatureGraphicStyle(c);
      final logo = style['logo'] as String?;
      return Check(CheckStatus.ok, 'feature_graphic: ${items.map((i) => '${i.locale} "${i.caption.headline}"').join(', ')}, '
          '${logo == null ? 'text only' : 'logo ${p.relative(logo, from: c.root)}'}');
    } on BrandifyException catch (e) {
      return Check(CheckStatus.warn, 'feature_graphic: `brandify frame` can\'t make it', hint: e.message);
    }
  }

  /// Files that hold `${NAME}` values must stay out of git: `.env`, and the
  /// fastlane files those values are written into.
  Future<List<Check>> _secrets(BrandifyConfig c) async {
    final dotEnv = p.join(c.root, dotEnvFile);
    final written = <String>[
      for (final MapEntry(:key, :value) in (c.appStore?.values ?? const <String, String>{}).entries)
        if (envRefs(value).isNotEmpty)
          for (final code in _appStoreCodes(c, key))
            p.join(c.fastlaneDir, 'metadata', appStoreFiles[key]!.replaceAll('{locale}', code)),
    ];
    final paths = [if (File(dotEnv).existsSync() || written.isNotEmpty) dotEnv, ...written];
    if (paths.isEmpty) return const [];
    final tracked = <String>[];
    for (final path in paths) {
      final r = await _try('git', ['-C', c.root, 'check-ignore', '-q', '--no-index', path]);
      if (r == null || r.exitCode == 128) return const []; // no git, or not a repository
      if (r.exitCode == 1) tracked.add(p.relative(path, from: c.root));
    }
    if (tracked.isEmpty) return [Check(CheckStatus.ok, 'Secrets: .env and the files written from \${...} are git-ignored')];
    return [
      Check(CheckStatus.warn, 'Secrets: ${tracked.length} file${tracked.length == 1 ? '' : 's'} with \${...} values '
          '${tracked.length == 1 ? 'is' : 'are'} not git-ignored',
          hint: 'Add to .gitignore:\n${tracked.map((t) => '  $t').join('\n')}')
    ];
  }

  /// App Store locale folders an `app_store.<key>` file is written to.
  List<String> _appStoreCodes(BrandifyConfig c, String key) => appStoreFiles[key]!.startsWith('{locale}/')
      ? [
          for (final l in c.metadata.keys)
            if (c.storeLocaleFor(Store.appStore, l) case final code?) code
        ]
      : [''];

  // -- Android ---------------------------------------------------------------

  Future<List<Check>> _android(List<AndroidDeviceConfig> devices) async {
    final sdk = AndroidSdk.locate(env);
    final adb = await _try(sdk.adb, ['version']);
    if (adb == null || adb.exitCode != 0) {
      return [
        _unavailable('Android: adb not found', devices,
            fix: 'Install the Android SDK platform-tools. brandify looks in \$ANDROID_HOME, \$ANDROID_SDK_ROOT, '
                '~/Library/Android/sdk, ~/Android/Sdk, then PATH.')
      ];
    }
    final checks = [
      Check(CheckStatus.ok, 'Android: ${LineSplitter.split(adb.stdout).first.trim()} (${sdk.adb})')
    ];

    final avds = devices.where((d) => d.avd != null).toList();
    final list = await _try(sdk.emulator, ['-list-avds']);
    if (list == null || list.exitCode != 0) {
      checks.add(Check(avds.isEmpty ? CheckStatus.warn : CheckStatus.fail, 'Android: emulator not found',
          hint: 'Install the Android Emulator (sdkmanager "emulator") into the SDK that has adb.'));
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
        devices.isEmpty
            ? Check(CheckStatus.skip, 'iOS: needs macOS')
            : _unavailable('iOS: needs macOS', devices, fix: 'iOS simulators run only on macOS.')
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
    // A Gemfile next to brandify.yaml that lists fastlane wins: it runs with
    // `bundle exec`, often from vendor/bundle, and isn't on PATH.
    final gemfile = File(p.join(_root, 'Gemfile'));
    final bundled = gemfile.existsSync() &&
        RegExp(r'''^\s*gem\s+['"]fastlane['"]''', multiLine: true).hasMatch(gemfile.readAsStringSync());
    if (bundled) {
      final version = _fastlaneVersion(
          await _try('bundle', ['exec', 'fastlane', '--version'], workingDirectory: _root));
      if (version == null) {
        return Check(CheckStatus.warn, 'fastlane: in the Gemfile but not installed',
            hint: 'Run `bundle install` next to brandify.yaml.');
      }
      return Check(CheckStatus.ok, 'fastlane $version (bundle exec, from the Gemfile)');
    }
    final version = _fastlaneVersion(await _try('fastlane', ['--version']));
    if (version == null) {
      return Check(CheckStatus.skip, 'fastlane not found (optional)',
          hint: 'Only needed to upload what `brandify export` writes (supply, deliver). Install it, or add '
              '`gem "fastlane"` to a Gemfile next to brandify.yaml and run `bundle install`.');
    }
    return Check(CheckStatus.ok, 'fastlane $version');
  }

  static String? _fastlaneVersion(CommandResult? r) =>
      r == null || r.exitCode != 0 ? null : RegExp(r'fastlane (\d+\.\d+\.\d+)').firstMatch(r.stdout)?.group(1);
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
