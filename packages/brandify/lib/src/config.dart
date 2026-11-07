import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'process.dart';

class ConfigException extends BrandifyException {
  ConfigException(super.message);
}

/// `brandify.yaml`. `app` is accepted and reserved for later tasks.
class BrandifyConfig {
  BrandifyConfig({
    required this.root,
    required this.locales,
    required this.devices,
    required this.capture,
    FrameConfig? frame,
  }) : frame = frame ?? FrameConfig();

  /// Directory holding `brandify.yaml`; relative paths resolve against it.
  final String root;
  final List<String> locales;
  final List<DeviceConfig> devices;
  final CaptureConfig capture;
  final FrameConfig frame;

  String get outputDir => p.normalize(p.join(root, capture.output));

  String get framedDir => p.normalize(p.join(root, frame.output));

  static const _topKeys = {'app', 'locales', 'devices', 'capture', 'frame'};

  static BrandifyConfig load(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw ConfigException(
          'No config at $path. Create brandify.yaml (see the brandify README) '
          'or pass --config.');
    }
    return parse(file.readAsStringSync(),
        root: p.dirname(p.absolute(path)), sourceUrl: Uri.file(path));
  }

  static BrandifyConfig parse(String source,
      {required String root, Uri? sourceUrl}) {
    final YamlNode doc;
    try {
      doc = loadYamlNode(source, sourceUrl: sourceUrl);
    } on YamlException catch (e) {
      throw ConfigException(e.toString());
    }
    final top = _map(doc, 'the config file');
    _rejectUnknown(top, _topKeys);

    final locales = _list(top, 'locales', required: true).map((n) {
      final v = _scalarString(n, 'locales entry');
      if (!_localePattern.hasMatch(v)) {
        throw _err(n, 'Invalid locale "$v". Use BCP 47 tags such as en-US, de-DE, zh-Hans.');
      }
      return v;
    }).toList();
    if (locales.isEmpty) throw _err(top.nodes['locales']!, 'List at least one locale.');
    if (locales.toSet().length != locales.length) {
      throw _err(top.nodes['locales']!, 'Duplicate locale.');
    }

    final devices = <DeviceConfig>[];
    for (final n in _list(top, 'devices', required: true)) {
      final d = DeviceConfig._parse(n);
      if (devices.any((e) => e.id == d.id)) {
        throw _err(n, 'Duplicate device id "${d.id}".');
      }
      devices.add(d);
    }
    if (devices.isEmpty) throw _err(top.nodes['devices']!, 'List at least one device.');

    final captureNode = top.nodes['capture'];
    final capture = captureNode == null
        ? CaptureConfig()
        : CaptureConfig._parse(_map(captureNode, 'capture'));

    final frameNode = top.nodes['frame'];
    final frame = frameNode == null
        ? FrameConfig()
        : FrameConfig._parse(_map(frameNode, 'frame'), locales);

    return BrandifyConfig(
        root: root, locales: locales, devices: devices, capture: capture, frame: frame);
  }
}

enum DevicePlatform { android, ios }

sealed class DeviceConfig {
  DeviceConfig(this.id);
  final String id;
  DevicePlatform get platform;

  static DeviceConfig _parse(YamlNode node) {
    final m = _map(node, 'device');
    final id = _string(m, 'id', required: true)!;
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id)) {
      throw _err(m.nodes['id']!,
          'Device id "$id" must be lowercase letters, digits, "_" or "-" (it becomes a folder name).');
    }
    final platform = _string(m, 'platform', required: true);
    switch (platform) {
      case 'android':
        _rejectUnknown(m, {'id', 'platform', 'avd', 'serial', 'emulator_args'});
        final avd = _string(m, 'avd'), serial = _string(m, 'serial');
        if ((avd == null) == (serial == null)) {
          throw _err(m, 'Android device "$id" needs exactly one of `avd` (boot or reuse an emulator) or `serial` (an already-connected device).');
        }
        return AndroidDeviceConfig(id,
            avd: avd,
            serial: serial,
            emulatorArgs: _list(m, 'emulator_args')
                .map((n) => _scalarString(n, 'emulator_args entry'))
                .toList());
      case 'ios':
        _rejectUnknown(m, {'id', 'platform', 'simulator', 'udid'});
        final sim = _string(m, 'simulator'), udid = _string(m, 'udid');
        if ((sim == null) == (udid == null)) {
          throw _err(m, 'iOS device "$id" needs exactly one of `simulator` (a name, e.g. "iPhone 17 Pro Max") or `udid`.');
        }
        return IosDeviceConfig(id, simulator: sim, udid: udid);
      default:
        throw _err(m.nodes['platform']!, 'platform must be `android` or `ios`.');
    }
  }
}

class AndroidDeviceConfig extends DeviceConfig {
  AndroidDeviceConfig(super.id,
      {this.avd, this.serial, this.emulatorArgs = const []});
  final String? avd;
  final String? serial;
  final List<String> emulatorArgs;
  @override
  DevicePlatform get platform => DevicePlatform.android;
}

class IosDeviceConfig extends DeviceConfig {
  IosDeviceConfig(super.id, {this.simulator, this.udid});
  final String? simulator;
  final String? udid;
  @override
  DevicePlatform get platform => DevicePlatform.ios;
}

class CaptureConfig {
  CaptureConfig({
    this.test = 'integration_test/brandify_test.dart',
    this.port = 47123,
    this.output = 'build/brandify/raw',
    this.bootTimeout = const Duration(minutes: 5),
    this.runTimeout = const Duration(minutes: 20),
    this.stableMaxAttempts = 10,
    this.stableInterval = const Duration(milliseconds: 300),
  });

  final String test;
  final int port;
  final String output;
  final Duration bootTimeout;
  final Duration runTimeout;
  final int stableMaxAttempts;
  final Duration stableInterval;

  static CaptureConfig _parse(YamlMap m) {
    _rejectUnknown(m, {
      'test', 'port', 'output', 'boot_timeout_s', 'run_timeout_s',
      'stable_max_attempts', 'stable_interval_ms', //
    });
    final d = CaptureConfig();
    int intOr(String k, int def, {int min = 1, int max = 1 << 30}) {
      final n = m.nodes[k];
      if (n == null) return def;
      final v = n is YamlScalar ? n.value : null;
      if (v is! int || v < min || v > max) {
        throw _err(n, '`$k` must be an integer between $min and $max.');
      }
      return v;
    }

    return CaptureConfig(
      test: _string(m, 'test') ?? d.test,
      port: intOr('port', d.port, min: 1024, max: 65535),
      output: _string(m, 'output') ?? d.output,
      bootTimeout: Duration(seconds: intOr('boot_timeout_s', d.bootTimeout.inSeconds)),
      runTimeout: Duration(seconds: intOr('run_timeout_s', d.runTimeout.inSeconds)),
      stableMaxAttempts: intOr('stable_max_attempts', d.stableMaxAttempts, min: 2),
      stableInterval: Duration(
          milliseconds: intOr('stable_interval_ms', d.stableInterval.inMilliseconds, min: 0)),
    );
  }
}

/// How the device sits in the store image.
enum FrameDeviceStyle {
  /// The screen alone, rounded corners and a shadow.
  screen,

  /// The screen in a plain drawn bezel.
  bezel,
}

/// A named slide design. Only `caption_top` so far.
enum FrameTemplate {
  /// Caption at the top, the whole device below it above a bottom margin,
  /// the same size on every slide of a device (`caption_area`).
  captionTop('caption_top');

  const FrameTemplate(this.id);
  final String id;
}

class Caption {
  const Caption(this.headline, [this.subheadline]);
  final String headline;
  final String? subheadline;
  Map<String, Object?> toJson() =>
      {'headline': headline, if (subheadline != null) 'subheadline': subheadline};
}

/// `frame:`. Every key is optional.
///
/// ```yaml
/// frame:
///   template: caption_top                # the slide design (only one so far)
///   caption_area: auto                   # or a share of the height above the device
///   background: ['#0B1F3A', '#2E5BFF']   # one colour, or a top-to-bottom gradient
///   device: screen                       # or bezel
///   font: fonts/NotoSansSC-Bold.ttf      # caption font, e.g. for CJK
///   captions:
///     en-US:
///       home: Everything in one place    # headline only
///       add_task: {headline: Add a task, subheadline: In two taps}
/// ```
class FrameConfig {
  FrameConfig({
    this.output = 'build/brandify/framed',
    this.template = FrameTemplate.captionTop,
    this.captionArea,
    this.background = const [0xFFF2F2F7],
    this.device = FrameDeviceStyle.screen,
    this.font,
    this.captions = const {},
  });

  final String output;
  final FrameTemplate template;

  /// Share of the canvas height from the top to the device, or null (auto):
  /// sized from the tallest caption of each device. Either way every slide
  /// of a device shows the phone at the same size and place.
  final double? captionArea;

  /// ARGB colours: one is a solid fill, several a vertical gradient.
  final List<int> background;
  final FrameDeviceStyle device;

  /// Caption font file, relative to the config's directory.
  final String? font;

  /// locale -> shot name -> caption. Empty: no captions.
  final Map<String, Map<String, Caption>> captions;

  static FrameConfig _parse(YamlMap m, List<String> locales) {
    _rejectUnknown(m, {'output', 'template', 'caption_area', 'background', 'device', 'font', 'captions'});
    final d = FrameConfig();

    var template = d.template;
    final tn = m.nodes['template'];
    if (tn != null) {
      final v = _scalarString(tn, '`template`');
      template = FrameTemplate.values.firstWhere((t) => t.id == v,
          orElse: () => throw _err(tn,
              'Unknown template "$v". Available: ${FrameTemplate.values.map((t) => t.id).join(', ')}.'));
    }

    var captionArea = d.captionArea;
    final an = m.nodes['caption_area'];
    if (an != null && !(an is YamlScalar && an.value == 'auto')) {
      final v = an is YamlScalar ? an.value : null;
      if (v is! num || v < 0.05 || v > 0.6) {
        throw _err(an, '`caption_area` is `auto` (the default: sized from the tallest caption) '
            'or a share of the canvas height between 0.05 and 0.6.');
      }
      captionArea = v.toDouble();
    }

    var background = d.background;
    final bg = m.nodes['background'];
    if (bg != null) {
      final nodes = bg is YamlList ? bg.nodes : [bg];
      if (nodes.isEmpty) throw _err(bg, '`background` needs at least one colour.');
      background = [for (final n in nodes) _color(n)];
    }

    var device = d.device;
    final dn = m.nodes['device'];
    if (dn != null) {
      final v = _scalarString(dn, '`device`');
      device = FrameDeviceStyle.values.firstWhere((e) => e.name == v,
          orElse: () => throw _err(dn, '`device` must be `screen` or `bezel`.'));
    }

    final captions = <String, Map<String, Caption>>{};
    final cn = m.nodes['captions'];
    if (cn != null) {
      final byLocale = _map(cn, '`captions`');
      for (final MapEntry(key: k, value: v) in byLocale.nodes.entries) {
        final locale = _scalarString(k as YamlNode, 'captions locale');
        if (!locales.contains(locale)) {
          throw _err(k, 'Captions for "$locale", which is not in `locales` (${locales.join(', ')}).');
        }
        final shots = <String, Caption>{};
        for (final MapEntry(key: sk, value: sv) in _map(v, 'captions for $locale').nodes.entries) {
          final shot = _scalarString(sk as YamlNode, 'shot name');
          if (sv is YamlScalar) {
            shots[shot] = Caption(_scalarString(sv, 'caption for $shot'));
          } else {
            final cm = _map(sv, 'caption for $shot');
            _rejectUnknown(cm, {'headline', 'subheadline'});
            shots[shot] = Caption(_string(cm, 'headline', required: true)!, _string(cm, 'subheadline'));
          }
        }
        captions[locale] = shots;
      }
    }

    return FrameConfig(
      output: _string(m, 'output') ?? d.output,
      template: template,
      captionArea: captionArea,
      background: background,
      device: device,
      font: _string(m, 'font'),
      captions: captions,
    );
  }
}

int _color(YamlNode n) {
  final v = n is YamlScalar && n.value is String ? n.value as String : null;
  final match = v == null ? null : RegExp(r'^#([0-9a-fA-F]{6}|[0-9a-fA-F]{8})$').firstMatch(v);
  if (match == null) {
    throw _err(n, 'Colours are quoted hex strings: "#RRGGBB" or "#AARRGGBB".');
  }
  final hex = match.group(1)!;
  return int.parse(hex.length == 6 ? 'FF$hex' : hex, radix: 16);
}

final _localePattern =
    RegExp(r'^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?$');

ConfigException _err(YamlNode node, String message) =>
    ConfigException(node.span.message(message));

YamlMap _map(YamlNode node, String what) {
  if (node is YamlMap) return node;
  throw _err(node, 'Expected $what to be a map.');
}

void _rejectUnknown(YamlMap m, Set<String> known) {
  for (final k in m.nodes.keys) {
    final key = (k as YamlNode).value;
    if (!known.contains(key)) {
      throw _err(k, 'Unknown key `$key`. Expected one of: ${known.join(', ')}.');
    }
  }
}

String _scalarString(YamlNode n, String what) {
  if (n is YamlScalar && n.value is String && (n.value as String).isNotEmpty) {
    return n.value as String;
  }
  throw _err(n, 'Expected $what to be a non-empty string.');
}

String? _string(YamlMap m, String key, {bool required = false}) {
  final n = m.nodes[key];
  if (n == null) {
    if (required) throw _err(m, 'Missing `$key`.');
    return null;
  }
  return _scalarString(n, '`$key`');
}

List<YamlNode> _list(YamlMap m, String key, {bool required = false}) {
  final n = m.nodes[key];
  if (n == null) {
    if (required) throw _err(m, 'Missing `$key`.');
    return const [];
  }
  if (n is YamlList) return n.nodes;
  throw _err(n, 'Expected `$key` to be a list.');
}
