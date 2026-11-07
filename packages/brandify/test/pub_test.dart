import 'dart:io';

import 'package:brandify/src/logger.dart';
import 'package:brandify/src/pub.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

class _Null implements IOSink {
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

void main() {
  late Directory ws;
  late String app;
  final logger = Logger(out: _Null(), err: _Null());

  setUp(() {
    ws = Directory.systemTemp.createTempSync('bf_pub');
    app = p.join(ws.path, 'example');
    Directory(app).createSync();
  });
  tearDown(() => ws.deleteSync(recursive: true));

  File write(String rel, {DateTime? at}) {
    final f = File(p.join(ws.path, rel))
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    if (at != null) f.setLastModifiedSync(at);
    return f;
  }

  final t0 = DateTime(2026, 1, 1);
  final t1 = DateTime(2026, 1, 2);

  test('finds the workspace package config above the app', () {
    expect(packageConfigFor(app), isNull);
    write('.dart_tool/package_config.json');
    expect(packageConfigFor(app)!.path, p.join(ws.path, '.dart_tool', 'package_config.json'));
    write('example/.dart_tool/package_config.json');
    expect(packageConfigFor(app)!.path, p.join(app, '.dart_tool', 'package_config.json'));
  });

  test('up to date only when resolved after pubspec.yaml and the lock', () {
    write('example/pubspec.yaml', at: t0);
    write('pubspec.lock', at: t0);
    expect(packagesUpToDate(app), isFalse, reason: 'never resolved');
    write('.dart_tool/package_config.json', at: t1);
    expect(packagesUpToDate(app), isTrue);
    write('pubspec.lock', at: t1.add(const Duration(minutes: 1)));
    expect(packagesUpToDate(app), isFalse, reason: 'lock changed since');
  });

  test('runs pub get only when needed, and explains a failure', () async {
    write('example/pubspec.yaml', at: t0);
    write('.dart_tool/package_config.json', at: t1);
    var runner = FakeRunner();
    await ensurePackages(root: app, runner: runner, logger: logger);
    expect(runner.calls, isEmpty);

    write('example/pubspec.yaml', at: t1.add(const Duration(minutes: 1)));
    await ensurePackages(root: app, runner: runner, logger: logger);
    expect(runner.calls, ['flutter pub get']);

    runner = FakeRunner([(_, __) => failed('No route to host')]);
    await expectLater(ensurePackages(root: app, runner: runner, logger: logger),
        throwsA(predicate((e) => '$e'.contains('No route to host') && '$e'.contains('--no-pub'))));
  });
}
