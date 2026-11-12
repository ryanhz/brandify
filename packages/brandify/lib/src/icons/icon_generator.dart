import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config.dart';
import '../logger.dart';
import '../png.dart';
import '../process.dart';

/// `brandify icons`: Android and iOS launcher icons from `app.logo_path`, made
/// by flutter_launcher_icons (which must be a dev dependency of the app).
/// brandify writes that tool's config to [configPath] in its own build folder
/// and runs `dart run flutter_launcher_icons -f <it>` in the project, so
/// nothing of yours is edited but the icons.
class IconGenerator {
  IconGenerator({required this.config, required this.runner, required this.logger, this.dart = 'dart'});

  final BrandifyConfig config;
  final ProcessRunner runner;
  final Logger logger;
  final String dart;

  static const package = 'flutter_launcher_icons';

  String get configPath => p.join(config.auxDir, 'flutter_launcher_icons.yaml');

  /// The absolute logo path, after checking it is a square PNG, and a
  /// warning if it is smaller than the App Store icon.
  ({String path, String? warning}) checkLogo() {
    config.app.require(['logo_path'], command: 'icons');
    final logo = p.normalize(p.join(config.root, config.app.logoPath!));
    final f = File(logo);
    if (!f.existsSync()) {
      throw BrandifyException('app.logo_path: ${p.relative(logo)} does not exist.');
    }
    final head = f.openSync();
    final size = pngSize(head.readSync(32));
    head.closeSync();
    if (size == null) throw BrandifyException('app.logo_path: ${p.relative(logo)} is not a PNG.');
    if (size.width != size.height) {
      throw BrandifyException('app.logo_path: ${p.relative(logo)} is ${size.width}×${size.height}; '
          'launcher icons need a square image (1024×1024 is best).');
    }
    return (
      path: logo,
      warning: size.width >= 1024
          ? null
          : 'app.logo_path is ${size.width}×${size.height}; the App Store icon is 1024×1024, so it '
              'will be scaled up and look soft.',
    );
  }

  /// Whether the app's pubspec.yaml lists flutter_launcher_icons.
  bool hasDependency() {
    final f = File(p.join(config.root, 'pubspec.yaml'));
    if (!f.existsSync()) return false;
    try {
      final y = loadYaml(f.readAsStringSync()) as YamlMap?;
      return [y?['dev_dependencies'], y?['dependencies']].any((d) => d is YamlMap && d.containsKey(package));
    } catch (_) {
      return false;
    }
  }

  String toolConfig(String logo) => '''
# Written by `brandify icons` from app.logo_path in brandify.yaml, and rewritten
# on every run: change brandify.yaml, not this file.
$package:
  image_path: ${jsonEncode(logo)}
  android: true
  ios: true
  remove_alpha_ios: true   # the App Store rejects icons with an alpha channel
''';

  Future<void> run() async {
    final (:path, :warning) = checkLogo();
    final logo = path;
    if (warning != null) logger.warn(warning);
    if (!hasDependency()) {
      throw BrandifyException('`brandify icons` runs $package, which is not in your pubspec.yaml. '
          'Add it: `flutter pub add dev:$package`.');
    }
    File(configPath)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(toolConfig(logo));
    logger.info('Generating launcher icons from ${p.relative(logo, from: config.root)} ($package)');
    final r = await runner.run(dart, ['run', package, '-f', configPath],
        timeout: const Duration(minutes: 5), workingDirectory: config.root);
    final out = '${r.stdout}\n${r.stderr}'.trim();
    if (r.exitCode != 0) {
      throw BrandifyException('`$dart run $package -f ${p.relative(configPath)}` failed (exit ${r.exitCode}):\n'
          '${out.split('\n').map((l) => '  | $l').join('\n')}');
    }
    for (final l in LineSplitter.split(out)) {
      logger.detail(l);
    }
    logger.info('Launcher icons written to android/app/src/main/res/mipmap-* and '
        'ios/Runner/Assets.xcassets/AppIcon.appiconset.');
  }
}
