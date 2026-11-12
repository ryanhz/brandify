import 'dart:io';

import 'package:brandify/src/config.dart';
import 'package:brandify/src/icons/icon_generator.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/process.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import 'fakes.dart';

class _Sink implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

const _pubspec = 'name: acme\ndependencies:\n  flutter: {sdk: flutter}\n'
    'dev_dependencies:\n  flutter_launcher_icons: ^0.14.4\n';

void main() {
  late Directory root;
  late _Sink out;

  void write(String rel, List<int> bytes) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);
  List<int> png(int w, int h) => img.encodePng(img.Image(width: w, height: h));

  setUp(() {
    root = Directory.systemTemp.createTempSync('bf_icons');
    out = _Sink();
    write('pubspec.yaml', _pubspec.codeUnits);
  });
  tearDown(() => root.deleteSync(recursive: true));

  IconGenerator icons(FakeRunner runner, {String? logo = 'assets/logo.png'}) => IconGenerator(
      config: BrandifyConfig.parse(
          'locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\n'
          'app: {name: Acme${logo == null ? '' : ', logo_path: $logo'}}\n',
          root: root.path),
      runner: runner,
      logger: Logger(out: out, err: out));

  Matcher fails(String fragment) =>
      throwsA(isA<BrandifyException>().having((e) => e.message, 'message', contains(fragment)));

  test('writes the tool config in build/brandify and runs flutter_launcher_icons with -f', () async {
    write('assets/logo.png', png(1024, 1024));
    final r = FakeRunner();
    final gen = icons(r);
    await gen.run();

    final config = p.join(root.path, 'build', 'brandify', 'flutter_launcher_icons.yaml');
    expect(gen.configPath, config);
    final y = (loadYaml(File(config).readAsStringSync()) as YamlMap)['flutter_launcher_icons'] as YamlMap;
    expect(y['image_path'], p.join(root.path, 'assets', 'logo.png'));
    expect([y['android'], y['ios'], y['remove_alpha_ios']], [true, true, true]);
    expect(r.calls, ['dart run flutter_launcher_icons -f $config']);
    expect(File(p.join(root.path, 'flutter_launcher_icons.yaml')).existsSync(), isFalse,
        reason: 'nothing written into the project itself');
    expect(out.lines, isNot(contains(startsWith('warning'))));
  });

  test('logo_path missing, not found, not a PNG, not square: clear errors, nothing run', () async {
    final r = FakeRunner();
    await expectLater(icons(r, logo: null).run(),
        throwsA(isA<ConfigException>().having((e) => e.message, 'm', contains('`brandify icons` needs `app.logo_path`'))));
    await expectLater(icons(r).run(), fails('assets/logo.png does not exist'));
    write('assets/logo.png', 'GIF89a'.codeUnits);
    await expectLater(icons(r).run(), fails('is not a PNG'));
    write('assets/logo.png', png(1024, 512));
    await expectLater(icons(r).run(), fails('1024×512; launcher icons need a square image'));
    expect(r.calls, isEmpty);
  });

  test('needs flutter_launcher_icons in pubspec.yaml', () async {
    write('assets/logo.png', png(1024, 1024));
    write('pubspec.yaml', 'name: acme\ndependencies:\n  flutter: {sdk: flutter}\n'.codeUnits);
    final r = FakeRunner();
    await expectLater(icons(r).run(), fails('flutter pub add dev:flutter_launcher_icons'));
    expect(r.calls, isEmpty);
  });

  test('a small logo is a warning; a tool failure shows its output', () async {
    write('assets/logo.png', png(512, 512));
    final r = FakeRunner([(_, __) => CommandResult(1, 'Image not found'.codeUnits, 'boom')]);
    await expectLater(icons(r).run(), fails('  | Image not found'));
    expect(out.lines, contains(contains('512×512; the App Store icon is 1024×1024')));
  });
}
