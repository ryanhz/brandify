import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'device/android.dart';
import 'doctor.dart' show parseAvdList;
import 'logger.dart';
import 'process.dart';

/// The AVD written when none is found; `doctor` then points at it.
const placeholderAvd = 'Pixel_8_API_36';

String brandifyYamlTemplate({required String avd, required bool avdFound}) => '''
# brandify: store screenshots from a real emulator / simulator.
# Run `dart run brandify doctor` to check this setup.

# BCP 47 tags; each becomes its own capture (the app runs with that locale).
locales: [en-US]

devices:
  - id: pixel
    platform: android
    avd: $avd${avdFound ? '' : '   # TODO: one of `emulator -list-avds`'}   # booted headless if not running
  - id: iphone69
    platform: ios
    simulator: iPhone 17 Pro Max    # App Store 6.9" (1320×2868), the size it requires; macOS only

capture:
  test: integration_test/brandify_test.dart

frame:
  background: ['#0B1F3A', '#2E5BFF']   # one colour, or a top-to-bottom gradient
  # One caption per locale and shot, matching the shot('...') names in the test.
  captions:
    en-US:
      home: {headline: Your headline here, subheadline: One line on what your app does}

# export:                            # `dart run brandify export` -> fastlane folders
#   locales:                         # only where a locale has no automatic store code
#     de-AT: {play: de-DE, app_store: de-DE}
''';

String captureTestTemplate({required String package, required bool hasMain}) => '''
// Store screenshots, taken by `dart run brandify capture` on every device and
// locale in brandify.yaml. Each shot('name') is one screenshot, in this order.
import 'package:brandify_flutter/brandify_flutter.dart';
${hasMain ? "import 'package:$package/main.dart' as app;\n" : ''}
void main() {
  brandifyTest('store screenshots', (tester, shot) async {
${hasMain ? '''    app.main();
    await tester.pumpAndSettle(); // use tester.pump(duration) if something animates forever
''' : '''    // TODO: start your app, e.g. `await tester.pumpWidget(const MyApp());`
'''}    await shot('home');

    // More screens (add `import 'package:flutter_test/flutter_test.dart';` for `find`):
    //   await tester.tap(find.byKey(const Key('settings')));
    //   await tester.pumpAndSettle();
    //   await shot('settings');
    //   await shot('search', keyboard: Keyboard.show);  // with the real keyboard up
  });
}
''';

/// `brandify init`: writes `brandify.yaml` and the capture test into a
/// Flutter app. Never overwrites without [force].
class Initializer {
  Initializer({required this.root, required this.runner, required this.logger, Map<String, String>? env})
      : env = env ?? Platform.environment;

  final String root;
  final ProcessRunner runner;
  final Logger logger;
  final Map<String, String> env;

  Future<List<String>> run({bool force = false}) async {
    final pubspec = File(p.join(root, 'pubspec.yaml'));
    if (!pubspec.existsSync()) {
      throw BrandifyException('No pubspec.yaml in $root. Run `brandify init` in your Flutter app\'s folder.');
    }
    final y = loadYaml(pubspec.readAsStringSync()) as YamlMap?;
    final deps = y?['dependencies'] as YamlMap?;
    final flutterSdk = deps?['flutter'];
    if (flutterSdk is! YamlMap || flutterSdk['sdk'] != 'flutter') {
      throw BrandifyException('${pubspec.path} is not a Flutter app (no `flutter: {sdk: flutter}` dependency).');
    }
    final package = y!['name'] as String;

    final config = p.join(root, 'brandify.yaml');
    final test = p.join(root, 'integration_test', 'brandify_test.dart');
    final existing = [config, test].where((f) => File(f).existsSync()).toList();
    if (existing.isNotEmpty && !force) {
      throw BrandifyException('${existing.map((f) => p.relative(f, from: root)).join(' and ')} '
          '${existing.length == 1 ? 'exists' : 'exist'}; nothing written. Pass --force to overwrite.');
    }

    final avds = await _avds();
    final yaml = brandifyYamlTemplate(avd: avds.firstOrNull ?? placeholderAvd, avdFound: avds.isNotEmpty);
    BrandifyConfig.parse(yaml, root: root); // the template must always be valid
    final hasMain = File(p.join(root, 'lib', 'main.dart')).existsSync();

    File(config).writeAsStringSync(yaml);
    File(test)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(captureTestTemplate(package: package, hasMain: hasMain));
    logger.info('Wrote brandify.yaml and integration_test/brandify_test.dart.');
    if (avds.isNotEmpty) {
      logger.info('Android: using AVD ${avds.first}${avds.length > 1 ? ' (also found: ${avds.skip(1).join(', ')})' : ''}.');
    } else {
      logger.warn('no Android AVD found; brandify.yaml names "$placeholderAvd". Set an AVD from '
          '`emulator -list-avds`, or remove the pixel device.');
    }

    final devDeps = y['dev_dependencies'] as YamlMap?;
    final missing = [
      for (final d in ['brandify_flutter', 'brandify'])
        if (!(deps?.containsKey(d) ?? false) && !(devDeps?.containsKey(d) ?? false)) 'dev:$d'
    ];
    logger.info('\nNext:');
    var n = 0;
    if (missing.isNotEmpty) logger.info('  ${++n}. flutter pub add ${missing.join(' ')}');
    if (!hasMain) logger.info('  ${++n}. Start your app in integration_test/brandify_test.dart (see the TODO).');
    logger.info('  ${++n}. Add a shot(\'...\') per screenshot, and a caption per shot in brandify.yaml.');
    logger.info('  ${++n}. dart run brandify doctor');
    logger.info('  ${++n}. dart run brandify capture && dart run brandify frame && dart run brandify export');
    return [config, test];
  }

  Future<List<String>> _avds() async {
    try {
      final r = await runner.run(AndroidSdk.locate(env).emulator, ['-list-avds'],
          timeout: const Duration(seconds: 30));
      return r.exitCode == 0 ? parseAvdList(r.stdout) : const [];
    } on BrandifyException {
      return const [];
    }
  }
}
