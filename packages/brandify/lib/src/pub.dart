import 'dart:io';

import 'package:path/path.dart' as p;

import 'logger.dart';
import 'process.dart';

/// The `.dart_tool/package_config.json` that resolves [root]: its own, or a
/// pub workspace's above it. Null if none.
File? packageConfigFor(String root) {
  var dir = p.normalize(p.absolute(root));
  while (true) {
    final f = File(p.join(dir, '.dart_tool', 'package_config.json'));
    if (f.existsSync()) return f;
    final parent = p.dirname(dir);
    if (parent == dir) return null;
    dir = parent;
  }
}

/// Whether [root]'s dependencies are resolved for Flutter: the package config
/// and `.flutter-plugins-dependencies` both exist and are newer than
/// `pubspec.yaml` and the `pubspec.lock` next to the package config.
///
/// The package config alone isn't enough: `dart pub get` (which `dart run`
/// does implicitly, e.g. right after `flutter clean`) writes it but not the
/// plugin list, and a `flutter test --no-pub` then builds an Android app whose
/// Gradle build can't find any plugin. Every app brandify captures has at
/// least one plugin (integration_test), so the plugin list always exists once
/// `flutter pub get` has run.
bool packagesUpToDate(String root) {
  final config = packageConfigFor(root);
  if (config == null) return false;
  final plugins = File(p.join(root, '.flutter-plugins-dependencies'));
  if (!plugins.existsSync()) return false;
  final inputs = [
    File(p.join(root, 'pubspec.yaml')),
    File(p.join(config.parent.parent.path, 'pubspec.lock')),
  ];
  return [config, plugins].every((out) {
    final resolved = out.lastModifiedSync();
    return inputs.every((f) => !f.existsSync() || !f.lastModifiedSync().isAfter(resolved));
  });
}

/// Resolves dependencies once, only when they are out of date, so every
/// following `flutter test` can run with `--no-pub` (no network, no
/// re-resolving per locale).
Future<void> ensurePackages({
  required String root,
  required ProcessRunner runner,
  required Logger logger,
  String flutter = 'flutter',
}) async {
  if (packagesUpToDate(root)) return;
  logger.info('resolving dependencies (flutter pub get)');
  final r =
      await runner.run(flutter, ['pub', 'get'], timeout: const Duration(minutes: 5), workingDirectory: root);
  if (r.exitCode != 0) {
    final out = '${r.stdout}\n${r.stderr}'.trim();
    throw BrandifyException('`flutter pub get` failed in $root (exit ${r.exitCode}). brandify '
        'runs it once, then every `flutter test` with --no-pub. Fix it, or run it yourself '
        'when you are back online.\n${out.split('\n').map((l) => '  | $l').join('\n')}');
  }
}
