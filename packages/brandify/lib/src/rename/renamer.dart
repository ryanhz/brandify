import 'dart:io';

import 'package:path/path.dart' as p;

import '../config.dart';
import '../process.dart';

/// One value `rename` changes, for the summary.
class RenameChange {
  RenameChange(this.what, this.from, this.to);
  final String what;
  final String? from;
  final String to;
}

/// Everything `rename` would do, computed without touching a file.
class RenamePlan {
  final changes = <RenameChange>[];

  /// Absolute path -> new content (edited or moved-to files).
  final writes = <String, String>{};

  /// Absolute paths of moved files' old locations.
  final deletes = <String>[];

  /// One line per file: what happens to it, relative to the project.
  final files = <String>[];

  /// Folders a move may leave empty, deepest first, removed if they are.
  final emptyDirs = <String>[];

  /// Things `rename` leaves alone that the user should know about.
  final notes = <String>[];

  bool get isEmpty => writes.isEmpty && deletes.isEmpty;
}

/// `brandify rename`: sets the app's display name, Android package and iOS
/// bundle ID in a Flutter project's native files.
///
/// - Android: `applicationId` and `namespace` in `android/app/build.gradle`
///   or `build.gradle.kts`; a `package` attribute left in an
///   AndroidManifest.xml; the `<application android:label>` (or the
///   `@string/` it points to); and the Kotlin/Java sources of the package
///   that holds `MainActivity`, moved to the new package's folder with their
///   `package` and `import` lines updated. Other files there move with them.
/// - iOS: `PRODUCT_BUNDLE_IDENTIFIER` in `Runner.xcodeproj` (the app's ID,
///   and IDs under it such as `<id>.RunnerTests`, keep their suffix) and
///   `CFBundleDisplayName` in `Info.plist`.
///
/// Anything it can't change safely (flavors with their own applicationId,
/// bundle IDs set from build settings) is an error before any file changes.
class Renamer {
  Renamer({required this.root});

  /// The Flutter project (the folder with `brandify.yaml`).
  final String root;

  String _p(String rel) => p.join(root, rel);
  String _rel(String path) => p.relative(path, from: root);

  RenamePlan plan(AppConfig app) {
    app.require(['name', 'android_package', 'ios_bundle_id'], command: 'rename');
    final plan = RenamePlan();
    final hasAndroid = Directory(_p('android')).existsSync();
    final hasIos = Directory(_p('ios')).existsSync();
    if (!hasAndroid && !hasIos) {
      throw BrandifyException('No android/ or ios/ folder in $root. Run `brandify rename` in your '
          'Flutter app\'s folder (or pass --config).');
    }
    if (hasAndroid) {
      _android(plan, app.name!, app.androidPackage!);
    } else {
      plan.notes.add('No android/ folder: Android left out.');
    }
    if (hasIos) {
      _ios(plan, app.name!, app.iosBundleId!);
    } else {
      plan.notes.add('No ios/ folder: iOS left out.');
    }
    return plan;
  }

  void apply(RenamePlan plan) {
    for (final d in plan.deletes) {
      File(d).deleteSync();
    }
    for (final MapEntry(key: path, value: content) in plan.writes.entries) {
      File(path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(content);
    }
    for (final dir in plan.emptyDirs) {
      final d = Directory(dir);
      if (d.existsSync() && d.listSync().isEmpty) d.deleteSync();
    }
  }

  // -- Android ---------------------------------------------------------------

  void _android(RenamePlan plan, String name, String package) {
    final gradle = [_p('android/app/build.gradle.kts'), _p('android/app/build.gradle')]
        .firstWhere((f) => File(f).existsSync(),
            orElse: () => throw BrandifyException('No android/app/build.gradle.kts or build.gradle.'));
    var text = File(gradle).readAsStringSync();

    final ids = _gradleString('applicationId').allMatches(text).toList();
    if (ids.isEmpty) {
      throw BrandifyException('No `applicationId = "…"` in ${_rel(gradle)}; set it by hand.');
    }
    if (ids.length > 1) {
      throw BrandifyException('${_rel(gradle)} sets applicationId ${ids.length} times (product flavors?). '
          'brandify rename handles one; change them by hand.');
    }
    final oldId = ids.single.group(3)!;
    final namespaces = _gradleString('namespace').allMatches(text).toList();
    if (namespaces.length > 1) {
      throw BrandifyException('${_rel(gradle)} sets namespace ${namespaces.length} times; change it by hand.');
    }
    final edited = <String>[];
    if (oldId != package) {
      plan.changes.add(RenameChange('Android package', oldId, package));
      edited.add('applicationId');
    }
    if (namespaces.isNotEmpty && namespaces.single.group(3) != package) {
      edited.add('namespace');
    }
    // Replace from the end so earlier offsets stay valid.
    for (final m in [...ids, ...namespaces]..sort((a, b) => b.start.compareTo(a.start))) {
      text = text.replaceRange(m.start, m.end, '${m.group(1)}${m.group(2)}$package${m.group(2)}');
    }
    if (edited.isNotEmpty) {
      plan.writes[gradle] = text;
      plan.files.add('~ ${_rel(gradle)} (${edited.join(', ')})');
    }

    final manifest = _p('android/app/src/main/AndroidManifest.xml');
    if (!File(manifest).existsSync()) throw BrandifyException('No ${_rel(manifest)}.');
    for (final rel in [
      'android/app/src/main/AndroidManifest.xml',
      'android/app/src/debug/AndroidManifest.xml',
      'android/app/src/profile/AndroidManifest.xml',
    ]) {
      final f = File(_p(rel));
      if (!f.existsSync()) continue;
      final xml = f.readAsStringSync();
      final m = _manifestPackage.firstMatch(xml);
      if (m != null && m.group(2) != package) {
        plan.writes[f.path] = xml.replaceRange(m.start, m.end, '${m.group(1)}$package${m.group(3)}');
        plan.files.add('~ $rel (package)');
      }
    }

    _androidLabel(plan, manifest, name);
    _moveSources(plan, package);
  }

  /// `key = "value"` / `key "value"` (Groovy), not `applicationIdSuffix`.
  static RegExp _gradleString(String key) => RegExp('(\\b$key\\s*(?:=\\s*)?)(["\'])([^"\'\\n]+)\\2');

  static final _manifestPackage = RegExp(r'(<manifest\b[^>]*?\bpackage\s*=\s*")([^"]*)(")');
  static final _applicationLabel = RegExp(r'(<application\b[^>]*?\bandroid:label\s*=\s*")([^"]*)(")');

  void _androidLabel(RenamePlan plan, String manifest, String name) {
    final xml = plan.writes[manifest] ?? File(manifest).readAsStringSync();
    final m = _applicationLabel.firstMatch(xml);
    if (m == null) {
      throw BrandifyException('No android:label on <application> in ${_rel(manifest)}; add one.');
    }
    final current = m.group(2)!;
    if (current.startsWith('@string/')) {
      final key = current.substring('@string/'.length);
      final strings = _p('android/app/src/main/res/values/strings.xml');
      final f = File(strings);
      final s = f.existsSync() ? f.readAsStringSync() : '';
      final sm = RegExp('(<string\\s+name="${RegExp.escape(key)}"[^>]*>)([^<]*)(</string>)').firstMatch(s);
      if (sm == null) {
        throw BrandifyException('android:label is $current, but ${_rel(strings)} has no string "$key"; '
            'set it by hand.');
      }
      final old = _androidUnescape(_xmlUnescape(sm.group(2)!));
      if (old != name) {
        plan.changes.add(RenameChange('Android display name', old, name));
        plan.writes[strings] =
            s.replaceRange(sm.start, sm.end, '${sm.group(1)}${_xmlEscape(_androidEscape(name))}${sm.group(3)}');
        plan.files.add('~ ${_rel(strings)} ($key)');
      }
      if (Directory(_p('android/app/src/main/res')).listSync().any((d) =>
          p.basename(d.path).startsWith('values-') && File(p.join(d.path, 'strings.xml')).existsSync())) {
        plan.notes.add('Translated app names in res/values-*/strings.xml are left as they are.');
      }
      return;
    }
    final old = _androidUnescape(_xmlUnescape(current));
    if (old == name) return;
    plan.changes.add(RenameChange('Android display name', old, name));
    final label = _xmlEscape(name.startsWith(RegExp('[@?]')) ? '\\$name' : name);
    plan.writes[manifest] = xml.replaceRange(m.start, m.end, '${m.group(1)}$label${m.group(3)}');
    if (!plan.files.contains('~ ${_rel(manifest)} (package)')) {
      plan.files.add('~ ${_rel(manifest)} (android:label)');
    } else {
      plan.files[plan.files.indexOf('~ ${_rel(manifest)} (package)')] = '~ ${_rel(manifest)} (package, android:label)';
    }
  }

  void _moveSources(RenamePlan plan, String package) {
    final roots = [for (final l in ['kotlin', 'java']) _p('android/app/src/main/$l')]
        .where((d) => Directory(d).existsSync())
        .toList();
    final activities = [
      for (final r in roots)
        ...Directory(r).listSync(recursive: true).whereType<File>().where((f) =>
            const {'MainActivity.kt', 'MainActivity.java'}.contains(p.basename(f.path)))
    ];
    if (activities.isEmpty) {
      plan.notes.add('No MainActivity.kt or .java under android/app/src/main: no sources moved.');
      return;
    }
    if (activities.length > 1) {
      throw BrandifyException('More than one MainActivity: '
          '${activities.map((f) => _rel(f.path)).join(', ')}. Move the sources by hand.');
    }
    final decl = RegExp(r'^\s*package\s+([\w.]+)', multiLine: true)
        .firstMatch(activities.single.readAsStringSync())
        ?.group(1);
    if (decl == null) {
      throw BrandifyException('${_rel(activities.single.path)} has no `package` line.');
    }
    if (decl == package) return;

    final pkgLine = RegExp('^(\\s*package\\s+)${RegExp.escape(decl)}(?=[.;\\s]|\$)', multiLine: true);
    final importLine =
        RegExp('^(\\s*import\\s+(?:static\\s+)?)${RegExp.escape(decl)}(?=\\.)', multiLine: true);
    final moves = <String, String>{};
    for (final r in roots) {
      final oldDir = p.joinAll([r, ...decl.split('.')]);
      final newDir = p.joinAll([r, ...package.split('.')]);
      if (!Directory(oldDir).existsSync()) continue;
      for (final f in Directory(oldDir).listSync(recursive: true).whereType<File>()) {
        moves[f.path] = p.join(newDir, p.relative(f.path, from: oldDir));
      }
      // Folders the move may leave empty, deepest first, up to the source root.
      final dirs = <String>{};
      for (final from in moves.keys.where((f) => p.isWithin(oldDir, f))) {
        for (var d = p.dirname(from); p.isWithin(r, d); d = p.dirname(d)) {
          dirs.add(d);
        }
      }
      plan.emptyDirs.addAll(dirs.toList()..sort((a, b) => b.length.compareTo(a.length)));
    }
    final taken = moves.values.where((to) => File(to).existsSync() && !moves.containsKey(to)).toList();
    if (taken.isNotEmpty) {
      throw BrandifyException('Moving the sources to ${package.replaceAll('.', '/')} would overwrite '
          '${taken.map(_rel).join(', ')}. Move them by hand.');
    }
    for (final MapEntry(key: from, value: to) in moves.entries) {
      var content = File(from).readAsStringSync();
      if (const {'.kt', '.java'}.contains(p.extension(from))) {
        content = content
            .replaceAllMapped(pkgLine, (m) => '${m.group(1)}$package')
            .replaceAllMapped(importLine, (m) => '${m.group(1)}$package');
      }
      plan.deletes.add(from);
      plan.writes[to] = content;
      plan.files.add('> ${_rel(from)} -> ${_rel(to)}');
    }
  }

  // -- iOS -------------------------------------------------------------------

  void _ios(RenamePlan plan, String name, String bundleId) {
    final pbx = _p('ios/Runner.xcodeproj/project.pbxproj');
    if (!File(pbx).existsSync()) throw BrandifyException('No ${_rel(pbx)}.');
    final text = File(pbx).readAsStringSync();
    final matches = _bundleId.allMatches(text).toList();
    if (matches.isEmpty) throw BrandifyException('No PRODUCT_BUNDLE_IDENTIFIER in ${_rel(pbx)}.');
    final values = {for (final m in matches) m.group(3)!};
    final variable = values.where((v) => v.contains(r'$')).toList();
    if (variable.isNotEmpty) {
      throw BrandifyException('${_rel(pbx)} sets PRODUCT_BUNDLE_IDENTIFIER from a build setting '
          '(${variable.join(', ')}); change it where that is defined.');
    }
    // The app's ID: the one every other is, or is nested under (…RunnerTests).
    final sorted = values.toList()..sort((a, b) => a.length.compareTo(b.length));
    final oldId = sorted.first;
    final unrelated = values.where((v) => v != oldId && !v.startsWith('$oldId.')).toList();
    if (unrelated.isNotEmpty) {
      throw BrandifyException('${_rel(pbx)} has bundle IDs that are not $oldId or under it '
          '(${unrelated.join(', ')}): flavors or extensions brandify can\'t tell apart. Change them in Xcode.');
    }
    if (oldId != bundleId) {
      plan.changes.add(RenameChange('iOS bundle ID', oldId, bundleId));
      final updated = text.replaceAllMapped(_bundleId,
          (m) => '${m.group(1)}${m.group(2)}$bundleId${m.group(3)!.substring(oldId.length)}${m.group(2)};');
      plan.writes[pbx] = updated;
      final nested = values.where((v) => v != oldId).map((v) => '$bundleId${v.substring(oldId.length)}');
      plan.files.add('~ ${_rel(pbx)} (PRODUCT_BUNDLE_IDENTIFIER ×${matches.length}'
          '${nested.isEmpty ? '' : '; also ${nested.join(', ')}'})');
    }

    final plist = _p('ios/Runner/Info.plist');
    if (!File(plist).existsSync()) throw BrandifyException('No ${_rel(plist)}.');
    final xml = File(plist).readAsStringSync();
    final m = _displayName.firstMatch(xml);
    final old = m == null ? null : _xmlUnescape(m.group(2)!);
    if (old != null && old.contains(r'$(')) {
      throw BrandifyException('CFBundleDisplayName in ${_rel(plist)} is $old, a build setting; '
          'change it where that is defined.');
    }
    if (old == name) return;
    plan.changes.add(RenameChange('iOS display name', old, name));
    if (m != null) {
      plan.writes[plist] = xml.replaceRange(m.start, m.end, '${m.group(1)}${_xmlEscape(name)}${m.group(3)}');
    } else {
      final dict = xml.indexOf('<dict>');
      if (dict < 0) throw BrandifyException('${_rel(plist)} has no <dict>.');
      final at = dict + '<dict>'.length;
      plan.writes[plist] = '${xml.substring(0, at)}\n\t<key>CFBundleDisplayName</key>\n'
          '\t<string>${_xmlEscape(name)}</string>${xml.substring(at)}';
    }
    plan.files.add('~ ${_rel(plist)} (CFBundleDisplayName)');
  }

  static final _bundleId = RegExp(r'(PRODUCT_BUNDLE_IDENTIFIER = )("?)([^";\n]+)\2;');
  static final _displayName =
      RegExp(r'(<key>CFBundleDisplayName</key>\s*<string>)([^<]*)(</string>)');
}

String _xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _xmlUnescape(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');

/// Android string resources treat `'` and `"` specially and `\` as escape.
String _androidEscape(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll("'", "\\'").replaceAll('"', '\\"');

String _androidUnescape(String s) => s.replaceAllMapped(RegExp(r'\\(.)'), (m) => m.group(1)!);
