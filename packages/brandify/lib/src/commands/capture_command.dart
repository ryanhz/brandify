import 'package:args/command_runner.dart';

import '../capture/orchestrator.dart';
import '../config.dart';
import '../logger.dart';
import '../process.dart';

class CaptureCommand extends Command<int> {
  CaptureCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addMultiOption('device', abbr: 'd', help: 'Only these device ids (default: all).')
      ..addMultiOption('locale', abbr: 'l', help: 'Only these locales (default: all).')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show tool output.');
  }

  @override
  String get name => 'capture';
  @override
  String get description =>
      'Run the capture test on each device and locale and save raw screenshots.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final logger = Logger(verbose: a['verbose'] as bool);
    await capture(BrandifyConfig.load(a['config'] as String), logger,
        devices: (a['device'] as List<String>).toSet(), locales: (a['locale'] as List<String>).toSet());
    return 0;
  }
}

/// The capture step, shared by `capture` and `build`.
Future<List<CaptureResult>> capture(BrandifyConfig config, Logger logger,
    {Set<String> devices = const {}, Set<String> locales = const {}}) async {
  final results = await CaptureOrchestrator(config: config, runner: IoProcessRunner(), logger: logger)
      .run(devices: devices, locales: locales);
  final total = results.fold<int>(0, (n, r) => n + r.shots.length);
  logger.info('Captured $total screenshots in ${results.length} device/locale runs.');
  return results;
}
