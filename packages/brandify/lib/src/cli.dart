import 'dart:io';

import 'package:args/command_runner.dart';

import 'commands/build_command.dart';
import 'commands/capture_command.dart';
import 'commands/doctor_command.dart';
import 'commands/export_command.dart';
import 'commands/frame_command.dart';
import 'commands/init_command.dart';
import 'process.dart';

const brandifyVersion = '0.1.0';

/// Entry point for the CLI. Returns the process exit code.
Future<int> runBrandify(List<String> args) async {
  final runner = CommandRunner<int>(
    'brandify',
    'Turn an unbranded Flutter app into store-ready assets.',
  )
    ..argParser.addFlag('version', negatable: false, help: 'Print the version.')
    ..addCommand(InitCommand())
    ..addCommand(DoctorCommand())
    ..addCommand(CaptureCommand())
    ..addCommand(FrameCommand())
    ..addCommand(ExportCommand())
    ..addCommand(BuildCommand());

  try {
    final results = runner.parse(args);
    if (results['version'] == true) {
      print(brandifyVersion);
      return 0;
    }
    return await runner.runCommand(results) ?? 0;
  } on UsageException catch (e) {
    stderr.writeln(e);
    return 64;
  } on BrandifyException catch (e) {
    stderr.writeln('error: ${e.message}');
    return 1;
  }
}
