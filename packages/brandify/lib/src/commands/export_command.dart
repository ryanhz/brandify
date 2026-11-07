import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../export/fastlane_exporter.dart';
import '../logger.dart';

class ExportCommand extends Command<int> {
  ExportCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addMultiOption('device', abbr: 'd', help: 'Only these device ids (default: all captured).')
      ..addMultiOption('locale', abbr: 'l', help: 'Only these locales (default: all captured).')
      ..addFlag('replace',
          negatable: false,
          help: 'Delete images in the folders being written that brandify did not export '
              '(fastlane would upload them with the new set). Without it, they stop the export.')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show more detail.');
  }

  @override
  String get name => 'export';
  @override
  String get description =>
      'Copy framed screenshots into the fastlane folders (supply for Google Play, deliver for the '
      'App Store), named in capture order, and check them against the store rules.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final logger = Logger(verbose: a['verbose'] as bool);
    final config = BrandifyConfig.load(a['config'] as String);
    final written = FastlaneExporter(config: config, logger: logger).run(
        devices: (a['device'] as List<String>).toSet(),
        locales: (a['locale'] as List<String>).toSet(),
        replace: a['replace'] as bool);
    logger.info('Exported ${written.length} screenshots -> ${p.relative(config.fastlaneDir)}');
    return 0;
  }
}
