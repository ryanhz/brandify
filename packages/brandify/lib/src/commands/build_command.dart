import 'package:args/command_runner.dart';

import '../config.dart';
import '../logger.dart';
import '../process.dart';
import 'capture_command.dart' as steps;
import 'export_command.dart' as steps;
import 'frame_command.dart' as steps;

class BuildCommand extends Command<int> {
  BuildCommand() {
    argParser
      ..addOption('config', abbr: 'c', defaultsTo: 'brandify.yaml', help: 'Path to brandify.yaml.')
      ..addMultiOption('device', abbr: 'd', help: 'Only these device ids (default: all this machine can run).')
      ..addMultiOption('locale', abbr: 'l', help: 'Only these locales (default: all).')
      ..addFlag('replace',
          negatable: false,
          help: 'As for export: delete images in the folders being written that brandify did not export.')
      ..addFlag('verbose', abbr: 'v', negatable: false, help: 'Show tool output.');
  }

  @override
  String get name => 'build';
  @override
  String get description => 'Capture, frame and export in one run; stops at the first step that fails.';

  @override
  Future<int> run() async {
    final a = argResults!;
    final logger = Logger(verbose: a['verbose'] as bool);
    final config = BrandifyConfig.load(a['config'] as String);
    await BuildPipeline(logger: logger).run(config,
        devices: (a['device'] as List<String>).toSet(),
        locales: (a['locale'] as List<String>).toSet(),
        replace: a['replace'] as bool);
    return 0;
  }
}

typedef CaptureStep = Future<Map<String, Set<String>>> Function(
    BrandifyConfig config, Logger logger, Set<String> devices, Set<String> locales);
typedef FrameStep = Future<void> Function(
    BrandifyConfig config, Logger logger, Set<String> devices, Set<String> locales);
typedef ExportStep = void Function(
    BrandifyConfig config, Logger logger, Set<String> devices, Set<String> locales, bool replace);

/// `brandify build`: capture, then frame and export exactly what this
/// capture produced (so older captures of other devices or locales in the
/// raw folder are left out). A failing step stops the build and is named in
/// the error.
class BuildPipeline {
  BuildPipeline({required this.logger, CaptureStep? capture, FrameStep? frame, ExportStep? export})
      : _capture = capture ?? _captureStep,
        _frame = frame ?? ((c, l, d, lo) => steps.frame(c, l, devices: d, locales: lo)),
        _export = export ?? ((c, l, d, lo, r) => steps.export(c, l, devices: d, locales: lo, replace: r));

  final Logger logger;
  final CaptureStep _capture;
  final FrameStep _frame;
  final ExportStep _export;

  static Future<Map<String, Set<String>>> _captureStep(
      BrandifyConfig config, Logger logger, Set<String> devices, Set<String> locales) async {
    final results = await steps.capture(config, logger, devices: devices, locales: locales);
    return {for (final r in results) r.deviceId: {for (final s in results) if (s.deviceId == r.deviceId) s.locale}};
  }

  Future<void> run(BrandifyConfig config,
      {Set<String> devices = const {}, Set<String> locales = const {}, bool replace = false}) async {
    final captured = await _step('capture', () => _capture(config, logger, devices, locales));
    if (captured.isEmpty) throw BrandifyException('build stopped after capture: nothing was captured.');
    final capturedDevices = captured.keys.toSet();
    final capturedLocales = captured.values.expand((l) => l).toSet();
    await _step('frame', () => _frame(config, logger, capturedDevices, capturedLocales));
    await _step('export', () async => _export(config, logger, capturedDevices, capturedLocales, replace));
    logger.info('\nbuild done: ${capturedDevices.join(', ')} × ${capturedLocales.join(', ')}');
  }

  Future<T> _step<T>(String name, Future<T> Function() body) async {
    logger.info('\n== $name');
    try {
      return await body();
    } on BrandifyException catch (e) {
      throw BrandifyException('build stopped at $name: ${e.message}');
    }
  }
}
