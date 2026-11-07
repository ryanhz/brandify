import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../config.dart';
import '../frame/frame_job.dart';
import '../frame/frame_runner.dart';
import '../logger.dart';
import '../process.dart';

class FrameCommand extends Command<int> {
  FrameCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addMultiOption('device', abbr: 'd', help: 'Only these device ids (default: all captured).')
      ..addMultiOption('locale', abbr: 'l', help: 'Only these locales (default: all captured).')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show tool output.');
  }

  @override
  String get name => 'frame';
  @override
  String get description =>
      'Frame raw captures for the stores: background, caption, device style, store canvas size. '
      'The real status bar is kept as captured.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final logger = Logger(verbose: a['verbose'] as bool);
    final config = BrandifyConfig.load(a['config'] as String);
    final job = FrameJob.build(config,
        devices: (a['device'] as List<String>).toSet(),
        locales: (a['locale'] as List<String>).toSet(),
        logger: logger);
    final items = await FrameRunner(config: config, runner: IoProcessRunner(), logger: logger).run(job);
    logger.info('Framed ${items.length} screenshots -> ${p.relative(config.framedDir)}');
    return 0;
  }
}
