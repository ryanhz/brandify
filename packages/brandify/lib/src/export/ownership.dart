import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../process.dart';

/// What brandify wrote into the fastlane folder: path and SHA-256 of each
/// file, in [fileName] at its root. `export` and `metadata` share it. A file
/// is brandify's only while it is listed here and unchanged since, and
/// brandify only ever replaces or deletes such files.
class OwnershipRecord {
  OwnershipRecord._(this.root, this._files);

  /// Dotfiles are never matched by fastlane's globs.
  static const fileName = '.brandify-export.json';

  /// The fastlane folder.
  final String root;
  final Map<String, String> _files;

  String get path => p.join(root, fileName);

  static OwnershipRecord load(String root) {
    final f = File(p.join(root, fileName));
    if (!f.existsSync()) return OwnershipRecord._(root, {});
    try {
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return OwnershipRecord._(root, (j['files'] as Map<String, dynamic>).cast<String, String>());
    } catch (_) {
      throw BrandifyException('${p.relative(f.path)} is not a brandify export record. Delete it; '
          'brandify then treats every existing file in ${p.relative(root)} as not its own.');
    }
  }

  static String sha(List<int> bytes) => sha256.convert(bytes).toString();

  /// Key: relative to [root], always with `/`.
  String _rel(String path) => p.split(p.relative(path, from: root)).join('/');

  /// Whether [path], holding [bytes], is brandify's and unchanged since.
  bool owns(String path, List<int> bytes) => _files[_rel(path)] == sha(bytes);

  /// Records [path] as written by brandify, with its current content.
  void record(String path) => _files[_rel(path)] = sha(File(path).readAsBytesSync());

  void forget(String path) => _files.remove(_rel(path));

  void save() {
    // Forget files that are gone (deleted by hand, or by a deliver download).
    _files.removeWhere((rel, _) => !File(p.join(root, rel)).existsSync());
    final sorted = {for (final k in _files.keys.toList()..sort()) k: _files[k]};
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('${const JsonEncoder.withIndent('  ').convert({
            'brandify_export': 1,
            'note': 'Files written by `brandify export` and `brandify metadata`. brandify only '
                'deletes or replaces files listed here and unchanged since.',
            'files': sorted,
          })}\n');
  }
}
