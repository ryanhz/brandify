import 'package:args/command_runner.dart';

import '../config.dart';
import '../icons/icon_generator.dart';
import '../logger.dart';
import '../process.dart';

class IconsCommand extends Command<int> {
  IconsCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show flutter_launcher_icons\' output.');
  }

  @override
  String get name => 'icons';
  @override
  String get description => 'Generate the Android and iOS launcher icons from `app.logo_path` in brandify.yaml '
      '(runs flutter_launcher_icons, which must be a dev dependency).';

  @override
  Future<int> run() async {
    final config = BrandifyConfig.load(argResults!['config'] as String);
    await IconGenerator(
            config: config, runner: IoProcessRunner(), logger: Logger(verbose: argResults!['verbose'] as bool))
        .run();
    return 0;
  }
}
