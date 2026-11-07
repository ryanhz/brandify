import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/commands/build_command.dart';
import 'package:brandify/src/config.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/process.dart';
import 'package:test/test.dart';

void main() {
  final config = BrandifyConfig.parse('''
locales: [en-US, de-DE]
devices: [{id: pixel, platform: android, avd: P}, {id: iphone69, platform: ios, simulator: iPhone 17 Pro Max}]
''', root: Directory.systemTemp.path);

  late List<String> calls;
  late _Lines out;
  setUp(() {
    calls = [];
    out = _Lines();
  });

  BuildPipeline pipeline({Map<String, Set<String>>? captured, String? failAt}) {
    void step(String name, Set<String> d, Set<String> l, [bool? replace]) {
      calls.add('$name ${d.join(',')} ${l.join(',')}${replace == null ? '' : ' replace=$replace'}');
      if (failAt == name) throw BrandifyException('$name broke');
    }

    return BuildPipeline(
      logger: Logger(out: out, err: out),
      capture: (c, l, d, lo) async {
        step('capture', d, lo);
        return captured ?? {'pixel': {'en-US', 'de-DE'}};
      },
      frame: (c, l, d, lo) async => step('frame', d, lo),
      export: (c, l, d, lo, r) => step('export', d, lo, r),
    );
  }

  test('runs capture, frame and export on exactly what was captured', () async {
    await pipeline().run(config, locales: {'en-US', 'de-DE'}, replace: true);
    expect(calls, [
      'capture  en-US,de-DE',
      'frame pixel en-US,de-DE',
      'export pixel en-US,de-DE replace=true',
    ]);
    expect(out.text, allOf(contains('== capture'), contains('== export'), contains('build done')));
  });

  test('a failing step stops the build and is named', () async {
    await expectLater(pipeline(failAt: 'frame').run(config),
        throwsA(isA<BrandifyException>().having((e) => e.message, 'm', 'build stopped at frame: frame broke')));
    expect(calls.map((c) => c.split(' ').first), ['capture', 'frame']);
  });

  test('nothing captured stops before framing', () async {
    await expectLater(pipeline(captured: {}).run(config), throwsA(isA<BrandifyException>()));
    expect(calls.map((c) => c.split(' ').first), ['capture']);
  });
}

class _Lines implements IOSink {
  final _b = StringBuffer();
  String get text => _b.toString();
  @override
  void writeln([Object? o = '']) => _b.writeln(o);
  @override
  Encoding encoding = utf8;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
