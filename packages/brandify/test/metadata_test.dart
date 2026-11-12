import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/config.dart';
import 'package:brandify/src/export/ownership.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/metadata/metadata_writer.dart';
import 'package:brandify/src/process.dart';
import 'package:brandify/src/store/slots.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Sink implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

const _full = '''
    name: Acme Tasks
    subtitle: Plan your day
    description: |
      Everything in one place.
      Works offline.
    keywords: [tasks, todo]
    release_notes: Faster sync.
''';

void main() {
  late Directory root;
  late _Sink out;
  late Logger logger;

  void write(String rel, String content) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  setUp(() {
    root = Directory.systemTemp.createTempSync('bf_meta');
    out = _Sink();
    logger = Logger(out: out, err: out);
    write('pubspec.yaml', 'name: acme\nversion: 1.2.0+42\n');
  });
  tearDown(() => root.deleteSync(recursive: true));
  String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();
  bool exists(String rel) => File(p.join(root.path, rel)).existsSync();

  BrandifyConfig config(String metadata, {String locales = '[en-US]', String extra = ''}) =>
      BrandifyConfig.parse('locales: $locales\ndevices: [{id: p, platform: android, avd: a}]\n'
          'metadata:\n$metadata$extra', root: root.path);

  List<MetadataFile> run(BrandifyConfig c,
          {Set<Store>? stores, Set<String>? locales, bool replace = false, int? versionCode}) =>
      MetadataWriter(config: c, logger: logger, versionCode: versionCode)
          .run(stores: stores, locales: locales, replace: replace);

  Matcher fails(String fragment) =>
      throwsA(isA<BrandifyException>().having((e) => e.message, 'message', contains(fragment)));

  test('writes deliver and supply files for every field', () {
    final written = run(config('  en-US:\n$_full'));
    expect(written, hasLength(9));
    expect(read('fastlane/metadata/en-US/name.txt'), 'Acme Tasks');
    expect(read('fastlane/metadata/en-US/subtitle.txt'), 'Plan your day');
    expect(read('fastlane/metadata/en-US/description.txt'), 'Everything in one place.\nWorks offline.');
    expect(read('fastlane/metadata/en-US/keywords.txt'), 'tasks,todo');
    expect(read('fastlane/metadata/en-US/release_notes.txt'), 'Faster sync.');
    expect(read('fastlane/metadata/android/en-US/title.txt'), 'Acme Tasks');
    expect(read('fastlane/metadata/android/en-US/short_description.txt'), 'Plan your day');
    expect(read('fastlane/metadata/android/en-US/full_description.txt'), startsWith('Everything'));
    expect(read('fastlane/metadata/android/en-US/changelogs/42.txt'), 'Faster sync.');
    expect(exists('fastlane/metadata/android/en-US/keywords.txt'), isFalse, reason: 'App Store only');

    final record = jsonDecode(read('fastlane/${OwnershipRecord.fileName}'))['files'] as Map;
    expect(record.keys, contains('metadata/android/en-US/changelogs/42.txt'));
    expect(record, hasLength(9));
  });

  test('optional fields that are absent are skipped', () {
    run(config('  en-US: {name: Acme, subtitle: Plan, description: Text}\n'));
    expect(exists('fastlane/metadata/en-US/name.txt'), isTrue);
    for (final f in ['subtitle.txt', 'keywords.txt', 'release_notes.txt']) {
      expect(exists('fastlane/metadata/en-US/$f'), f == 'subtitle.txt', reason: f);
    }
    expect(Directory(p.join(root.path, 'fastlane/metadata/android/en-US/changelogs')).existsSync(), isFalse);
  });

  test('missing required fields: every locale and store listed, nothing written', () {
    final c = config('  en-US: {name: Acme}\n  de-DE: {name: Acme, description: Text}\n',
        locales: '[en-US, de-DE]');
    expect(
        () => run(c),
        fails('[en-US] Google Play needs `subtitle` (short description), `description` (full description)'));
    try {
      run(c);
    } on BrandifyException catch (e) {
      expect(e.message, contains('[en-US] App Store needs `description`'));
      expect(e.message, contains('[de-DE] Google Play needs `subtitle` (short description)'));
      expect(e.message, isNot(contains('[de-DE] App Store')));
    }
    expect(Directory(p.join(root.path, 'fastlane')).existsSync(), isFalse);

    // App Store alone doesn't need a subtitle.
    run(c, stores: {Store.appStore}, locales: {'de-DE'});
    expect(exists('fastlane/metadata/de-DE/name.txt'), isTrue);
    expect(exists('fastlane/metadata/android'), isFalse);
  });

  test('store length limits', () {
    final long = 'x' * 31;
    final c = config('  en-US: {name: $long, subtitle: "${'s' * 40}", description: d, '
        'keywords: "${'ü' * 51}", release_notes: "${'r' * 501}"}\n');
    expect(() => run(c), fails('`name` is 31 characters; App Store takes at most 30'));
    try {
      run(c);
    } on BrandifyException catch (e) {
      expect(e.message, contains('`subtitle` is 40 characters; App Store takes at most 30'));
      expect(e.message, isNot(contains('Google Play takes at most 80')));
      expect(e.message, contains('`keywords` is 102 bytes; App Store takes at most 100'));
      expect(e.message, contains('`release_notes` is 501 characters; Google Play takes at most 500 for its changelog'));
    }
  });

  test('Play changelog name: --version-code, or the pubspec build number', () {
    final c = config('  en-US:\n$_full');
    run(c, versionCode: 7);
    expect(exists('fastlane/metadata/android/en-US/changelogs/7.txt'), isTrue);

    write('pubspec.yaml', 'name: acme\nversion: 1.2.0\n');
    expect(() => run(c), fails('no build number'));
    run(c, stores: {Store.appStore}); // App Store needs none
    run(config('  en-US: {name: A, subtitle: B, description: C}\n')); // nor do listings without notes
  });

  test('export.locales maps or leaves out a locale, as for export', () {
    final c = config('  de-AT: {name: A, subtitle: B, description: C}\n',
        locales: '[de-AT]', extra: 'export: {locales: {de-AT: {play: de-DE, app_store: none}}}\n');
    run(c);
    expect(exists('fastlane/metadata/android/de-DE/title.txt'), isTrue);
    expect(exists('fastlane/metadata/de-AT'), isFalse);
    expect(out.lines, contains(contains('left out of App Store')));

    expect(() => run(config('  de-AT: {name: A, subtitle: B, description: C}\n', locales: '[de-AT]')),
        fails('no listing language for "de-AT"'));
  });

  group('ownership', () {
    test('a file brandify did not write stops the run; --replace overwrites it', () {
      write('fastlane/metadata/en-US/description.txt', 'From deliver init');
      final c = config('  en-US:\n$_full');
      expect(() => run(c), fails('fastlane/metadata/en-US/description.txt'));
      expect(read('fastlane/metadata/en-US/description.txt'), 'From deliver init');
      expect(exists('fastlane/metadata/en-US/name.txt'), isFalse, reason: 'checked before writing');

      run(c, replace: true);
      expect(read('fastlane/metadata/en-US/description.txt'), startsWith('Everything'));
    });

    test('a file already holding the same text is adopted', () {
      write('fastlane/metadata/en-US/name.txt', 'Acme Tasks');
      run(config('  en-US:\n$_full'));
      final record = jsonDecode(read('fastlane/${OwnershipRecord.fileName}'))['files'] as Map;
      expect(record.keys, contains('metadata/en-US/name.txt'));
    });

    test('its own files are updated; edited ones are not its own any more', () {
      run(config('  en-US:\n$_full'));
      final written = run(config('  en-US:\n${_full.replaceFirst('Plan your day', 'Own your day')}'));
      expect(written.map((f) => p.basename(f.path)), unorderedEquals(['subtitle.txt', 'short_description.txt']));
      expect(read('fastlane/metadata/en-US/subtitle.txt'), 'Own your day');
      expect(out.lines, contains(contains('5 files (1 changed)')));

      write('fastlane/metadata/en-US/name.txt', 'Edited by hand');
      expect(() => run(config('  en-US:\n$_full')), fails('name.txt'));
    });

    test('an emptied field deletes the file brandify wrote, never one it did not', () {
      run(config('  en-US:\n$_full'));
      write('fastlane/metadata/en-US/keywords.txt', 'hand,made');
      run(config('  en-US: {name: Acme Tasks, subtitle: Plan your day, description: x}\n'));
      expect(exists('fastlane/metadata/en-US/subtitle.txt'), isTrue);
      expect(exists('fastlane/metadata/en-US/release_notes.txt'), isFalse);
      expect(exists('fastlane/metadata/android/en-US/changelogs/42.txt'), isFalse);
      expect(read('fastlane/metadata/en-US/keywords.txt'), 'hand,made');
      expect(out.lines, contains(contains('release_notes.txt (its field is now empty)')));
      final record = jsonDecode(read('fastlane/${OwnershipRecord.fileName}'))['files'] as Map;
      expect(record.keys, isNot(contains('metadata/en-US/release_notes.txt')));
    });

    test('shares the record with export, keeping its entries', () {
      write('fastlane/screenshots/en-US/1_home.png', 'png');
      final record = OwnershipRecord.load(p.join(root.path, 'fastlane'))
        ..record(p.join(root.path, 'fastlane/screenshots/en-US/1_home.png'))
        ..save();
      run(config('  en-US:\n$_full'));
      final files = jsonDecode(File(record.path).readAsStringSync())['files'] as Map;
      expect(files.keys, containsAll(['screenshots/en-US/1_home.png', 'metadata/en-US/name.txt']));
    });
  });

  test('no metadata block, or an unknown -l locale', () {
    final c = BrandifyConfig.parse('locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\n',
        root: root.path);
    expect(() => run(c), throwsA(isA<ConfigException>().having((e) => e.message, 'm', contains('no `metadata:`'))));
    expect(() => run(config('  en-US:\n$_full'), locales: {'fr-FR'}), fails('No metadata for fr-FR'));
  });
}
