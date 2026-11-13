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

# Your app's identity. Fill it in, then run (each is a separate command):
#   dart run brandify rename   # name and IDs -> android/ and ios/ (dry run; --force applies)
#   dart run brandify icons    # launcher icons from logo_path (needs dev:flutter_launcher_icons)
# Empty fields are fine until you run the command that needs them.
app:
  name:              # shown under the launcher icon, e.g. Acme Tasks
  android_package:   # Google Play applicationId, e.g. com.acme.tasks (fixed after the first upload)
  ios_bundle_id:     # App Store bundle ID, e.g. com.acme.tasks (fixed after the first upload)
  logo_path:         # square PNG, 1024×1024, relative to this file, e.g. assets/logo.png

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

# Store listing text per locale (each one must be in `locales`).
# `dart run brandify metadata` writes it into the fastlane folders for deliver / supply.
metadata:
  en-US:
    name:            # App Store name and Play title; required, at most 30 characters
    subtitle:        # App Store subtitle (optional, ≤ 30); Play short description (required, ≤ 80)
    description:     # full description, both stores; required, ≤ 4000. Use `|` for several lines
    keywords:        # App Store only, optional: [tasks, todo] or "tasks,todo", ≤ 100 bytes in all
    promotional_text:  # App Store only, optional, ≤ 170; can change without a new release
    release_notes:   # optional: App Store "What's New" (≤ 4000), Play changelog (≤ 500)

# App Store fields that aren't per-locale text; `brandify metadata` writes them too.
# App Store Connect needs primary_category, copyright, support_url, privacy_url and
# the review contact before you can submit; `brandify doctor` lists what's missing.
# Any value may be \${NAME}, read from the environment or from .env next to this file
# (NAME=value lines). Use that for secrets such as a demo password, and git-ignore
# .env and fastlane/metadata/review_information/demo_password.txt (doctor checks).
app_store:
  primary_category:    # e.g. productivity, utilities, education, "Photo & Video"
  secondary_category:  # optional
  copyright:           # e.g. 2026 Acme Inc.
  support_url:         # https://..., shown on the listing (every locale)
  privacy_url:         # https://..., your privacy policy (every locale)
  marketing_url:       # optional
  review:              # App Review information: only Apple's reviewers see it
    first_name:
    last_name:
    email:
    phone:             # with country code, e.g. +1 555 0100
    demo_user:         # only if the app needs a sign-in
    demo_password:     # e.g. \${REVIEW_DEMO_PASSWORD}, set in .env
    notes:             # anything a reviewer needs to know, e.g. how to reach a paid feature

# Google Play needs a 1024×500 feature graphic to publish. Uncomment to have
# `brandify frame` make one (logo left, name and subtitle right) and `brandify
# export` place it. Every key is optional; these are the defaults.
# feature_graphic:
#   background: ['#0B1F3A', '#2E5BFF']   # default: frame.background
#   text_color: '#FFFFFF'                # default: white or black, whichever reads better
#   logo: assets/logo.png                # default: app.logo_path; `none` for text only
#   font: fonts/Brand-Bold.ttf           # default: frame.font
#   text:                                # default: metadata.<locale> name and subtitle
#     en-US: {headline: Acme Tasks, subheadline: Plan your day}

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
    logger.info('  ${++n}. dart run brandify build    (capture, frame and export)');
    logger.info('  ${++n}. Fill in app:, metadata: and app_store: in brandify.yaml, then, when you want them:\n'
        '     dart run brandify rename     (name and IDs; commit first, it edits android/ and ios/)\n'
        '     dart run brandify icons      (launcher icons; needs dev:flutter_launcher_icons)\n'
        '     dart run brandify metadata   (store listing text -> fastlane)');
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
