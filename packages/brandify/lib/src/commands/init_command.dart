import 'dart:io';

import 'package:args/command_runner.dart';

import '../init.dart';
import '../logger.dart';
import '../process.dart';

class InitCommand extends Command<int> {
  InitCommand() {
    argParser.addFlag('force', negatable: false, help: 'Overwrite an existing brandify.yaml and capture test.');
  }

  @override
  String get name => 'init';
  @override
  String get description => 'Write brandify.yaml and integration_test/brandify_test.dart into this Flutter app.';

  @override
  Future<int> run() async {
    await Initializer(root: Directory.current.path, runner: IoProcessRunner(), logger: Logger())
        .run(force: argResults!['force'] as bool);
    return 0;
  }
}
