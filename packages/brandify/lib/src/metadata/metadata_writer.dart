import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../config.dart';
import '../export/ownership.dart';
import '../logger.dart';
import '../process.dart';
import '../store/slots.dart';

/// One text file a store listing is made of, filled from a `metadata:` key.
class MetadataField {
  const MetadataField(this.key, this.file, this.max, {this.required = false, this.bytes = false, this.label});

  /// The `metadata.<locale>` key it comes from.
  final String key;

  /// Relative to the locale's folder. `{versionCode}` is replaced.
  final String file;

  /// Longest the store accepts, in characters (or UTF-8 bytes if [bytes]).
  final int max;
  final bool required;
  final bool bytes;

  /// What the store calls it, when that isn't [key].
  final String? label;

  String get describe => label == null ? '`$key`' : '`$key` ($label)';
}

/// fastlane `deliver`: `<fastlane>/metadata/<locale>/`.
const appStoreFields = [
  MetadataField('name', 'name.txt', 30, required: true),
  MetadataField('subtitle', 'subtitle.txt', 30),
  MetadataField('description', 'description.txt', 4000, required: true),
  MetadataField('keywords', 'keywords.txt', 100, bytes: true),
  MetadataField('release_notes', 'release_notes.txt', 4000, label: "What's New"),
];

/// fastlane `supply`: `<fastlane>/metadata/android/<locale>/`.
const playFields = [
  MetadataField('name', 'title.txt', 30, required: true, label: 'title'),
  MetadataField('subtitle', 'short_description.txt', 80, required: true, label: 'short description'),
  MetadataField('description', 'full_description.txt', 4000, required: true, label: 'full description'),
  MetadataField('release_notes', 'changelogs/{versionCode}.txt', 500, label: 'changelog'),
];

List<MetadataField> fieldsOf(Store store) => store == Store.play ? playFields : appStoreFields;

/// A text file to write.
class MetadataFile {
  MetadataFile(this.locale, this.store, this.storeLocale, this.path, this.text);
  final String locale;
  final Store store;
  final String storeLocale;

  /// Absolute.
  final String path;
  final String text;
}

/// `brandify metadata`: writes the `metadata:` block of brandify.yaml as the
/// text files fastlane `deliver` (App Store) and `supply` (Google Play)
/// upload. Locales map to store codes as for `export`.
///
/// Every locale and store is checked (required fields, store length limits)
/// before anything is written. Like `export`, it only replaces or deletes
/// files in the [OwnershipRecord]; a file brandify didn't write (e.g. from
/// `fastlane deliver init`) stops it, unless it already holds the same text
/// or [replace] is set. A file it wrote for a field that is now empty is
/// deleted, so the store doesn't keep the old text. Other files in those
/// folders are never touched.
class MetadataWriter {
  MetadataWriter({required this.config, required this.logger, this.versionCode});

  final BrandifyConfig config;
  final Logger logger;

  /// Play changelog file name; read from pubspec.yaml's `version` (`1.2.0+42`)
  /// when null.
  final int? versionCode;

  List<MetadataFile> run({Set<Store>? stores, Set<String>? locales, bool replace = false}) {
    final (plan, obsolete) = this.plan(stores: stores, locales: locales);
    final owned = OwnershipRecord.load(config.fastlaneDir);

    final foreign = <String>[];
    final toWrite = <MetadataFile>[];
    for (final f in plan) {
      final file = File(f.path);
      if (!file.existsSync()) {
        toWrite.add(f);
        continue;
      }
      final bytes = file.readAsBytesSync();
      if (utf8.decode(bytes, allowMalformed: true) == f.text) {
        // Same text: nothing to write; recorded as brandify's below.
      } else if (owned.owns(f.path, bytes) || replace) {
        toWrite.add(f);
      } else {
        foreign.add(p.relative(f.path));
      }
    }
    if (foreign.isNotEmpty) {
      throw BrandifyException('These files hold other text, and brandify did not write them (or they '
          'changed since):\n${foreign.map((l) => '  - $l').join('\n')}\n'
          'Move the text into brandify.yaml and delete them, or run `brandify metadata --replace` to '
          'overwrite them.');
    }

    final deleted = <String>[];
    for (final path in obsolete) {
      final file = File(path);
      if (file.existsSync() && owned.owns(path, file.readAsBytesSync())) {
        file.deleteSync();
        owned.forget(path);
        deleted.add(path);
      }
    }
    for (final f in toWrite) {
      File(f.path)
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(f.text);
    }
    for (final f in plan) {
      owned.record(f.path);
    }
    owned.save();

    final byFolder = <(String, Store), List<MetadataFile>>{};
    for (final f in plan) {
      byFolder.putIfAbsent((f.locale, f.store), () => []).add(f);
    }
    for (final MapEntry(key: (locale, store), value: files) in byFolder.entries) {
      final changed = files.where(toWrite.contains).length;
      logger.info('[$locale] ${store.label} ${files.first.storeLocale}: ${files.length} files '
          '($changed changed) -> ${p.relative(_folder(store, files.first.storeLocale))}');
    }
    for (final d in deleted) {
      logger.info('removed ${p.relative(d)} (its field is now empty)');
    }
    return toWrite;
  }

  /// The files to write, and the paths of optional fields left empty (deleted
  /// if brandify wrote them). Throws, listing every problem, if a required
  /// field is missing or a text is too long.
  (List<MetadataFile>, List<String>) plan({Set<Store>? stores, Set<String>? locales}) {
    if (config.metadata.isEmpty) {
      throw ConfigException('brandify.yaml has no `metadata:` block to write. Add one per locale '
          '(`brandify init` writes a template; see the brandify README).');
    }
    final wantStores = stores == null || stores.isEmpty ? Store.values.toSet() : stores;
    final unknown = (locales ?? const {}).difference(config.metadata.keys.toSet());
    if (unknown.isNotEmpty) {
      throw BrandifyException('No metadata for ${unknown.join(', ')} in brandify.yaml. '
          'It has: ${config.metadata.keys.join(', ')}.');
    }

    final problems = validate(stores: wantStores, locales: locales);
    if (problems.isNotEmpty) {
      throw BrandifyException('Store metadata in brandify.yaml is not ready:\n'
          '${problems.map((l) => '  - $l').join('\n')}');
    }

    // Also looked up without release notes, to delete a changelog brandify
    // wrote for this version before they were removed.
    final needsVersion = wantStores.contains(Store.play) &&
        config.metadata.entries.any((e) => _selected(e.key, locales) && e.value.releaseNotes != null);
    final version = versionCode ?? _pubspecVersionCode(required: needsVersion);

    final plan = <MetadataFile>[];
    final obsolete = <String>[];
    final owner = <(Store, String), String>{};
    for (final MapEntry(key: locale, value: m) in config.metadata.entries) {
      if (!_selected(locale, locales)) continue;
      for (final store in Store.values.where(wantStores.contains)) {
        final code = config.storeLocaleFor(store, locale);
        if (code == null) {
          logger.info('[$locale] export.locales: left out of ${store.label}');
          continue;
        }
        final prev = owner[(store, code)];
        if (prev != null) {
          throw BrandifyException('Locales $prev and $locale both map to ${store.label} "$code". '
              'Give one of them another code (or `none`) in export.locales.');
        }
        owner[(store, code)] = locale;
        final folder = _folder(store, code);
        for (final field in fieldsOf(store)) {
          final value = m[field.key];
          if (field.key == 'release_notes' && store == Store.play && version == null) continue;
          final path = p.join(folder, field.file.replaceAll('{versionCode}', '$version'));
          if (value == null) {
            obsolete.add(path);
          } else {
            plan.add(MetadataFile(locale, store, code, path, value));
          }
        }
      }
    }
    return (plan, obsolete);
  }

  /// Every missing required field and every text over its store's limit,
  /// as one line each. Empty when [stores] can be written.
  List<String> validate({required Set<Store> stores, Set<String>? locales}) {
    final problems = <String>[];
    for (final MapEntry(key: locale, value: m) in config.metadata.entries) {
      if (!_selected(locale, locales)) continue;
      for (final store in Store.values.where(stores.contains)) {
        final missing = [
          for (final f in fieldsOf(store))
            if (f.required && m[f.key] == null) f.describe
        ];
        if (missing.isNotEmpty) {
          problems.add('[$locale] ${store.label} needs ${missing.join(', ')}');
        }
        for (final f in fieldsOf(store)) {
          final v = m[f.key];
          if (v == null) continue;
          final length = f.bytes ? utf8.encode(v).length : v.runes.length;
          if (length > f.max) {
            problems.add('[$locale] `${f.key}` is $length ${f.bytes ? 'bytes' : 'characters'}; '
                '${store.label} takes at most ${f.max}${f.label == null ? '' : ' for its ${f.label}'}');
          }
        }
      }
    }
    return problems;
  }

  bool _selected(String locale, Set<String>? locales) =>
      locales == null || locales.isEmpty || locales.contains(locale);

  String _folder(Store store, String code) => switch (store) {
        Store.play => p.join(config.fastlaneDir, 'metadata', 'android', code),
        Store.appStore => p.join(config.fastlaneDir, 'metadata', code),
      };

  int? _pubspecVersionCode({required bool required}) {
    final pubspec = File(p.join(config.root, 'pubspec.yaml'));
    Object? version;
    try {
      version = (loadYaml(pubspec.readAsStringSync()) as YamlMap?)?['version'];
    } catch (_) {}
    final build = version is String ? RegExp(r'\+(\d+)$').firstMatch(version)?.group(1) : null;
    if (build == null) {
      if (!required) return null;
      throw BrandifyException('Google Play changelogs are named after the versionCode, and '
          '${p.relative(pubspec.path)} has no build number (`version: 1.2.0+42` gives 42). '
          'Add one, or pass --version-code.');
    }
    return int.parse(build);
  }
}
