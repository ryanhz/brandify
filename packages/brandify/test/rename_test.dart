import 'dart:io';

import 'package:brandify/src/commands/rename_command.dart';
import 'package:brandify/src/config.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/process.dart';
import 'package:brandify/src/rename/renamer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

class _Sink implements IOSink {
  final lines = <String>[];
  @override
  void writeln([Object? o = '']) => lines.add('$o');
  @override
  dynamic noSuchMethod(Invocation i) => null;
}

const _gradleKts = '''
android {
    namespace = "com.example.my_app"
    defaultConfig {
        applicationId = "com.example.my_app"
        applicationIdSuffix = ".x"
    }
}
''';

const _manifest = '''
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:label="my_app"
        android:name="\${applicationName}">
        <activity android:name=".MainActivity" android:label="ignored"/>
    </application>
</manifest>
''';

const _pbxproj = '''
		97C147061CF9000F007C117D /* Debug */ = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.myApp;
		};
		331C8088294A63A400263BE5 /* Debug */ = {
				PRODUCT_BUNDLE_IDENTIFIER = com.example.myApp.RunnerTests;
		};
		97C147071CF9000F007C117D /* Release */ = {
				PRODUCT_BUNDLE_IDENTIFIER = "com.example.myApp";
		};
''';

const _plist = '''
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>My App</string>
	<key>CFBundleName</key>
	<string>my_app</string>
</dict>
</plist>
''';

const _activity = 'package com.example.my_app\n\nimport io.flutter.embedding.android.FlutterActivity\n\n'
    'class MainActivity : FlutterActivity()\n';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bf_rename'));
  tearDown(() => root.deleteSync(recursive: true));

  void write(String rel, String content) => File(p.join(root.path, rel))
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  String read(String rel) => File(p.join(root.path, rel)).readAsStringSync();
  bool exists(String rel) => File(p.join(root.path, rel)).existsSync();

  void project({String gradle = _gradleKts, String gradleName = 'build.gradle.kts'}) {
    write('android/app/$gradleName', gradle);
    write('android/app/src/main/AndroidManifest.xml', _manifest);
    write('android/app/src/main/kotlin/com/example/my_app/MainActivity.kt', _activity);
    write('ios/Runner.xcodeproj/project.pbxproj', _pbxproj);
    write('ios/Runner/Info.plist', _plist);
  }

  AppConfig app({
    String name = 'Acme Tasks',
    String android = 'com.acme.tasks',
    String ios = 'com.acme.Tasks',
  }) =>
      AppConfig(name: name, androidPackage: android, iosBundleId: ios);

  Renamer renamer() => Renamer(root: root.path);

  Matcher fails(String fragment) =>
      throwsA(isA<BrandifyException>().having((e) => e.message, 'message', contains(fragment)));

  Map<String, String> snapshot() => {
        for (final f in root.listSync(recursive: true).whereType<File>())
          p.relative(f.path, from: root.path): f.readAsStringSync()
      };

  test('plan shows old -> new and touches nothing', () {
    project();
    final before = snapshot();
    final plan = renamer().plan(app());
    expect(snapshot(), before);
    expect([for (final c in plan.changes) '${c.what}: ${c.from} -> ${c.to}'], [
      'Android package: com.example.my_app -> com.acme.tasks',
      'Android display name: my_app -> Acme Tasks',
      'iOS bundle ID: com.example.myApp -> com.acme.Tasks',
      'iOS display name: My App -> Acme Tasks',
    ]);
    expect(plan.files, contains('~ android/app/build.gradle.kts (applicationId, namespace)'));
    expect(plan.files, contains(contains('ios/Runner.xcodeproj/project.pbxproj (PRODUCT_BUNDLE_IDENTIFIER ×3; '
        'also com.acme.Tasks.RunnerTests)')));
  });

  test('apply: separate Android and iOS IDs, tests keep their suffix, sources move', () {
    project();
    final r = renamer();
    r.apply(r.plan(app()));

    final gradle = read('android/app/build.gradle.kts');
    expect(gradle, contains('namespace = "com.acme.tasks"'));
    expect(gradle, contains('applicationId = "com.acme.tasks"'));
    expect(gradle, contains('applicationIdSuffix = ".x"'));
    final manifest = read('android/app/src/main/AndroidManifest.xml');
    expect(manifest, contains('android:label="Acme Tasks"'));
    expect(manifest, contains('android:label="ignored"'), reason: 'only <application> is the app name');
    expect(read('android/app/src/main/kotlin/com/acme/tasks/MainActivity.kt'), startsWith('package com.acme.tasks\n'));
    expect(Directory(p.join(root.path, 'android/app/src/main/kotlin/com/example')).existsSync(), isFalse);

    final pbx = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = com.acme.Tasks;'));
    expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = com.acme.Tasks.RunnerTests;'));
    expect(pbx, contains('PRODUCT_BUNDLE_IDENTIFIER = "com.acme.Tasks";'));
    expect(pbx, isNot(contains('example')));
    final plist = read('ios/Runner/Info.plist');
    expect(plist, contains('<key>CFBundleDisplayName</key>\n\t<string>Acme Tasks</string>'));
    expect(plist, contains('<string>my_app</string>'), reason: 'CFBundleName is left alone');

    expect(r.plan(app()).isEmpty, isTrue, reason: 'a second run has nothing to do');
  });

  test('other sources in the package move with MainActivity, with package and import lines', () {
    project();
    write('android/app/src/main/kotlin/com/example/my_app/channels/Battery.kt',
        'package com.example.my_app.channels\n\nimport com.example.my_app.R\nimport com.example.other.X\n');
    write('android/app/src/main/java/com/example/my_app/Legacy.java',
        'package com.example.my_app;\nimport static com.example.my_app.Util.f;\n');
    write('android/app/src/main/kotlin/com/example/shared/Keep.kt', 'package com.example.shared\n');
    final r = renamer();
    r.apply(r.plan(app()));
    expect(read('android/app/src/main/kotlin/com/acme/tasks/channels/Battery.kt'),
        'package com.acme.tasks.channels\n\nimport com.acme.tasks.R\nimport com.example.other.X\n');
    expect(read('android/app/src/main/java/com/acme/tasks/Legacy.java'),
        'package com.acme.tasks;\nimport static com.acme.tasks.Util.f;\n');
    expect(exists('android/app/src/main/kotlin/com/example/shared/Keep.kt'), isTrue,
        reason: 'outside the old package');
    expect(Directory(p.join(root.path, 'android/app/src/main/kotlin/com/example/my_app')).existsSync(), isFalse);
  });

  test('a new package nested in the old one, and the reverse, keep every file', () {
    project();
    write('android/app/src/main/kotlin/com/example/my_app/Helper.kt', 'package com.example.my_app\n');
    var r = renamer();
    r.apply(r.plan(app(android: 'com.example.my_app.pro')));
    expect(read('android/app/src/main/kotlin/com/example/my_app/pro/MainActivity.kt'),
        startsWith('package com.example.my_app.pro\n'));
    expect(read('android/app/src/main/kotlin/com/example/my_app/pro/Helper.kt'), 'package com.example.my_app.pro\n');
    expect(exists('android/app/src/main/kotlin/com/example/my_app/MainActivity.kt'), isFalse);

    r = renamer();
    r.apply(r.plan(app(android: 'com.example')));
    expect(read('android/app/src/main/kotlin/com/example/MainActivity.kt'), startsWith('package com.example\n'));
    expect(read('android/app/src/main/kotlin/com/example/Helper.kt'), 'package com.example\n');
    expect(Directory(p.join(root.path, 'android/app/src/main/kotlin/com/example/my_app')).existsSync(), isFalse);
  });

  test('Groovy build.gradle, a manifest package attribute, an @string label', () {
    project(gradle: "android {\n    namespace 'com.example.my_app'\n    defaultConfig {\n"
        "        applicationId \"com.example.my_app\"\n    }\n}\n", gradleName: 'build.gradle');
    write('android/app/src/debug/AndroidManifest.xml', '<manifest package="com.example.my_app"/>');
    write('android/app/src/main/AndroidManifest.xml', _manifest.replaceFirst('"my_app"', '"@string/app_name"'));
    write('android/app/src/main/res/values/strings.xml',
        '<resources>\n    <string name="app_name">my_app</string>\n</resources>\n');
    final r = renamer();
    r.apply(r.plan(app(name: 'Tom & Jerry\'s')));
    final gradle = read('android/app/build.gradle');
    expect(gradle, contains("namespace 'com.acme.tasks'"));
    expect(gradle, contains('applicationId "com.acme.tasks"'));
    expect(read('android/app/src/debug/AndroidManifest.xml'), '<manifest package="com.acme.tasks"/>');
    expect(read('android/app/src/main/AndroidManifest.xml'), contains('android:label="@string/app_name"'));
    expect(read('android/app/src/main/res/values/strings.xml'), contains(r">Tom &amp; Jerry\'s</string>"));
    expect(read('ios/Runner/Info.plist'), contains("<string>Tom &amp; Jerry's</string>"));
    expect(r.plan(app(name: 'Tom & Jerry\'s')).isEmpty, isTrue, reason: 'escaped names read back');
  });

  test('refuses what it cannot change safely, before touching anything', () {
    project(gradle: '$_gradleKts\nproductFlavors { create("pro") { applicationId = "com.example.pro" } }\n');
    expect(() => renamer().plan(app()), fails('sets applicationId 2 times'));

    project();
    write('ios/Runner.xcodeproj/project.pbxproj', '$_pbxproj\t\tPRODUCT_BUNDLE_IDENTIFIER = com.other.widget;\n');
    expect(() => renamer().plan(app()), fails('com.other.widget'));

    write('ios/Runner.xcodeproj/project.pbxproj', 'PRODUCT_BUNDLE_IDENTIFIER = "\$(APP_ID)";\n');
    expect(() => renamer().plan(app()), fails('from a build setting'));

    project();
    write('android/app/src/main/kotlin/com/acme/tasks/MainActivity.kt', 'package com.acme.tasks\n');
    expect(() => renamer().plan(app()), fails('More than one MainActivity'));
  });

  test('missing app fields: a clear error naming them', () {
    project();
    expect(() => renamer().plan(AppConfig(name: 'Acme')),
        throwsA(isA<ConfigException>().having((e) => e.message, 'm',
            allOf(contains('`brandify rename` needs'), contains('`app.android_package`'), contains('`app.ios_bundle_id`')))));
  });

  test('an iOS-only project leaves Android out', () {
    write('ios/Runner.xcodeproj/project.pbxproj', _pbxproj);
    write('ios/Runner/Info.plist', _plist);
    final plan = renamer().plan(app());
    expect(plan.notes, contains('No android/ folder: Android left out.'));
    expect(plan.changes.map((c) => c.what), ['iOS bundle ID', 'iOS display name']);
  });

  test('the command: dry run without --force, then applies', () {
    project();
    final out = _Sink();
    final config = BrandifyConfig.parse(
        'locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\n'
        'app: {name: Acme Tasks, android_package: com.acme.tasks, ios_bundle_id: com.acme.tasks}\n',
        root: root.path);
    final before = snapshot();
    expect(rename(config, Logger(out: out, err: out), force: false), 0);
    expect(snapshot(), before);
    expect(out.lines, contains(contains('"com.example.my_app" -> "com.acme.tasks"')));
    expect(out.lines.last, contains('Dry run: nothing changed'));

    expect(rename(config, Logger(out: out, err: out), force: true), 0);
    expect(read('android/app/build.gradle.kts'), contains('"com.acme.tasks"'));
    expect(out.lines.last, contains('Renamed.'));
    rename(config, Logger(out: out, err: out), force: true);
    expect(out.lines.last, contains('Nothing to change'));
  });

  test('on a copy of the example app', () {
    final example = p.normalize(p.join(Directory.current.path, '..', '..', 'example'));
    for (final rel in [
      'android/app/build.gradle.kts',
      'android/app/src/main/AndroidManifest.xml',
      'android/app/src/debug/AndroidManifest.xml',
      'android/app/src/profile/AndroidManifest.xml',
      'android/app/src/main/kotlin/dev/brandify/brandify_example/MainActivity.kt',
      'ios/Runner.xcodeproj/project.pbxproj',
      'ios/Runner/Info.plist',
    ]) {
      write(rel, File(p.join(example, rel)).readAsStringSync());
    }
    final r = renamer();
    r.apply(r.plan(app()));
    final pbx = read('ios/Runner.xcodeproj/project.pbxproj');
    expect(RegExp('PRODUCT_BUNDLE_IDENTIFIER = com.acme.Tasks;').allMatches(pbx), hasLength(3));
    expect(RegExp('PRODUCT_BUNDLE_IDENTIFIER = com.acme.Tasks.RunnerTests;').allMatches(pbx), hasLength(3));
    expect(read('ios/Runner/Info.plist'), contains('<string>Acme Tasks</string>'));
    expect(read('android/app/src/main/kotlin/com/acme/tasks/MainActivity.kt'), contains('package com.acme.tasks'));
    expect(read('android/app/src/main/AndroidManifest.xml'), contains('android:label="Acme Tasks"'));
    expect(r.plan(app()).isEmpty, isTrue);
  }, skip: Directory(p.join('..', '..', 'example', 'ios')).existsSync() ? false : 'needs the repo\'s example/');
}
