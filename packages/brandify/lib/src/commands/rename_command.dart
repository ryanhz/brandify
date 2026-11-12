import 'package:args/command_runner.dart';

import '../config.dart';
import '../logger.dart';
import '../rename/renamer.dart';

class RenameCommand extends Command<int> {
  RenameCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addFlag('force',
          negatable: false,
          help: 'Change the files. Without it, rename only shows what it would change.');
  }

  @override
  String get name => 'rename';
  @override
  String get description => 'Set the display name, Android package and iOS bundle ID from `app:` in '
      'brandify.yaml in the Flutter project\'s android/ and ios/ files. A dry run unless --force; '
      'commit first.';

  @override
  Future<int> run() async {
    final config = BrandifyConfig.load(argResults!['config'] as String);
    final force = argResults!['force'] as bool;
    return rename(config, Logger(), force: force);
  }
}

/// Prints the plan and, with [force], applies it. Returns the exit code.
int rename(BrandifyConfig config, Logger logger, {required bool force}) {
  final renamer = Renamer(root: config.root);
  final plan = renamer.plan(config.app);
  for (final n in plan.notes) {
    logger.info('note: $n');
  }
  if (plan.isEmpty) {
    logger.info('Nothing to change: the project already uses this name and these IDs.');
    return 0;
  }
  final width = plan.changes.fold(0, (w, c) => c.what.length > w ? c.what.length : w);
  for (final c in plan.changes) {
    logger.info('  ${c.what.padRight(width)}  ${c.from == null ? '(not set)' : '"${c.from}"'} -> "${c.to}"');
  }
  logger.info('');
  for (final f in plan.files) {
    logger.info('  $f');
  }
  logger.info('');
  if (!force) {
    logger.info('Dry run: nothing changed. These are edits to your Flutter project, so commit first, '
        'then run `brandify rename --force`.');
    return 0;
  }
  renamer.apply(plan);
  logger.info('Renamed. Run `flutter clean` before the next build; review the changes with `git diff`.');
  return 0;
}
