import 'package:args/command_runner.dart';

import '../doctor.dart';
import '../logger.dart';
import '../process.dart';

class DoctorCommand extends Command<int> {
  DoctorCommand() {
    argParser.addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.');
  }

  @override
  String get name => 'doctor';
  @override
  String get description =>
      'Check Flutter, the config, and the tools and devices a capture needs (Android SDK, AVDs, Xcode, '
      'simulators; fastlane optional). Changes nothing.';

  @override
  Future<int> run() async {
    final checks = await Doctor(configPath: argResults!['config'] as String, runner: IoProcessRunner()).run();
    return printChecks(checks, Logger());
  }
}

/// Prints [checks] and returns the exit code: 1 if any failed.
int printChecks(List<Check> checks, Logger logger) {
  for (final c in checks) {
    logger.info('[${c.status.mark}] ${c.title}');
    if (c.hint != null && c.status != CheckStatus.ok) {
      for (final l in c.hint!.split('\n')) {
        logger.info('    $l');
      }
    }
  }
  final failed = checks.where((c) => c.status == CheckStatus.fail).length;
  final warned = checks.where((c) => c.status == CheckStatus.warn).length;
  logger.info('');
  logger.info(failed == 0
      ? 'Ready to capture${warned == 0 ? '' : ' ($warned warning${warned == 1 ? '' : 's'})'}.'
      : '$failed problem${failed == 1 ? '' : 's'} to fix before capturing.');
  return failed == 0 ? 0 : 1;
}
