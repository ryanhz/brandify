import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../logger.dart';
import '../metadata/metadata_writer.dart';
import '../process.dart';
import '../store/slots.dart';

class MetadataCommand extends Command<int> {
  MetadataCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addMultiOption('locale', abbr: 'l', help: 'Only these locales (default: all in `metadata:`).')
      ..addMultiOption('platform',
          abbr: 'p', allowed: ['android', 'ios'], help: 'Only this store (default: both).')
      ..addOption('version-code',
          help: 'Google Play changelog file name (default: the build number in pubspec.yaml).')
      ..addFlag('replace',
          negatable: false,
          help: 'Overwrite text files brandify did not write (e.g. from `fastlane deliver init`). '
              'Without it, they stop the run.');
  }

  @override
  String get name => 'metadata';
  @override
  String get description => 'Write the store listing text in brandify.yaml (`metadata:`) into the fastlane '
      'folders: name, subtitle, description, keywords, promotional text, release notes, and the App Store '
      'category, URLs, copyright and App Review information (`app_store:`).';

  @override
  Future<int> run() async {
    final a = argResults!;
    final vc = a['version-code'] as String?;
    final versionCode = vc == null ? null : int.tryParse(vc);
    if (vc != null && (versionCode == null || versionCode < 1)) {
      throw BrandifyException('--version-code must be a positive integer, not "$vc".');
    }
    final config = BrandifyConfig.load(a['config'] as String);
    final written = MetadataWriter(config: config, logger: Logger(), versionCode: versionCode).run(
      stores: {
        for (final pl in a['platform'] as List<String>) pl == 'android' ? Store.play : Store.appStore,
      },
      locales: (a['locale'] as List<String>).toSet(),
      replace: a['replace'] as bool,
    );
    Logger().info('Wrote ${written.length} metadata files -> ${p.relative(config.fastlaneDir)}');
    return 0;
  }
}
