import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'host_client.dart';

// Set by `brandify capture` through --dart-define.
const _port = int.fromEnvironment('BRANDIFY_PORT');
const _runId = String.fromEnvironment('BRANDIFY_RUN');
const _locale = String.fromEnvironment('BRANDIFY_LOCALE');
const _device = String.fromEnvironment('BRANDIFY_DEVICE');

/// What to do with the soft keyboard before a screenshot.
///
/// The real keyboard animates in after `enterText`, so without an explicit
/// choice the result depends on timing.
enum Keyboard {
  /// Hide it, keeping focus (the default).
  hide,

  /// Show it for the focused text field.
  show,

  /// Don't touch it.
  leave,
}

/// Parses a BCP 47 tag such as `en-US`, `zh-Hans` or `zh-Hans-CN`.
Locale parseLocaleTag(String tag) {
  final parts = tag.split(RegExp('[-_]'));
  String? script, country;
  for (final part in parts.skip(1)) {
    if (part.length == 4) {
      script = part;
    } else {
      country = part;
    }
  }
  return Locale.fromSubtags(
      languageCode: parts.first, scriptCode: script, countryCode: country);
}

/// Declares a screenshot test.
///
/// ```dart
/// void main() {
///   brandifyTest('store screenshots', (tester, shot) async {
///     await tester.pumpWidget(const MyApp());
///     await shot('home');
///   });
/// }
/// ```
///
/// Under `brandify capture`, each `shot(name)` makes the host capture the
/// real device screen, system bars included, and waits until the PNG is
/// saved. Run with plain `flutter test`, shots only settle the UI and log.
///
/// Before the body runs, this hides the debug banner, stops the cursor
/// blinking, and sets the locale brandify is capturing (as
/// `PlatformDispatcher.locale`).
void brandifyTest(
  String description,
  Future<void> Function(WidgetTester tester, Shot shot) body, {
  Timeout? timeout,
}) {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(description, (tester) async {
    final bannerWas = WidgetsApp.debugAllowBannerOverride;
    final cursorWas = EditableText.debugDeterministicCursor;
    WidgetsApp.debugAllowBannerOverride = false;
    EditableText.debugDeterministicCursor = true;
    addTearDown(() {
      WidgetsApp.debugAllowBannerOverride = bannerWas;
      EditableText.debugDeterministicCursor = cursorWas;
    });

    Locale? locale;
    if (_locale.isNotEmpty) {
      locale = parseLocaleTag(_locale);
      tester.platformDispatcher.localeTestValue = locale;
      tester.platformDispatcher.localesTestValue = [locale];
      addTearDown(() {
        tester.platformDispatcher.clearLocaleTestValue();
        tester.platformDispatcher.clearLocalesTestValue();
      });
    }

    final host = _port == 0 ? null : HostClient(port: _port, runId: _runId);
    // The real device's pixel ratio and view size: `brandify frame` needs
    // the dpr to size the virtual device that re-renders the capture.
    final view = tester.view;
    await host?.post('/hello', {
      'v': '$brandifyProtocolVersion',
      'dpr': '${view.devicePixelRatio}',
      'w': '${view.physicalSize.width.round()}',
      'h': '${view.physicalSize.height.round()}',
    });
    final shot = Shot._(tester, host, locale);
    await body(tester, shot);
    await host?.post('/done');
  }, timeout: timeout);
}

class Shot {
  Shot._(this._tester, this._host, this.locale);

  final WidgetTester _tester;
  final HostClient? _host;

  /// The locale being captured, or null outside `brandify capture`.
  final Locale? locale;

  /// The device id from brandify.yaml, or null outside `brandify capture`.
  String? get deviceId => _device.isEmpty ? null : _device;

  /// True when running under `brandify capture`.
  bool get isCapturing => _host != null;

  /// Settles the UI, then has the host capture the screen as `<name>.png`.
  ///
  /// [name]: lowercase letters, digits, `_` and `-`; unique per test.
  /// [settle]: `pumpAndSettle` first. If it times out (endless animation),
  /// a warning is printed and the shot is taken anyway; pass `false` for
  /// screens that never settle.
  Future<void> call(
    String name, {
    bool settle = true,
    Keyboard keyboard = Keyboard.hide,
    Duration settleTimeout = const Duration(seconds: 10),
  }) async {
    await _keyboard(keyboard);
    if (settle) {
      try {
        await _tester.pumpAndSettle(
            const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, settleTimeout);
      } on FlutterError catch (e) {
        if (!'$e'.contains('pumpAndSettle timed out')) rethrow;
        debugPrint('brandify: "$name" did not settle within $settleTimeout; '
            'capturing anyway (pass settle: false to skip waiting).');
      }
    } else {
      await _tester.pump();
    }
    final host = _host;
    if (host == null) {
      debugPrint('brandify: shot "$name" (not captured: run via `brandify capture`)');
      return;
    }
    final r = await host.post('/shot', {'name': name});
    debugPrint('brandify: shot "$name" ${r['width']}x${r['height']} '
        '(${r['attempts']} captures, ${r['ms']} ms)');
  }

  Future<void> _keyboard(Keyboard mode) async {
    if (mode == Keyboard.leave) return;
    final hide = mode == Keyboard.hide;
    if (!hide && FocusManager.instance.primaryFocus == null) {
      throw StateError('Keyboard.show needs a focused text field (tap or enterText first).');
    }
    await SystemChannels.textInput.invokeMethod<void>(hide ? 'TextInput.hide' : 'TextInput.show');
    // Wait for the inset to reach its final state so the app lays out once
    // more; the host's stability check covers the native animation itself.
    final sw = Stopwatch()..start();
    while (sw.elapsed < const Duration(seconds: 3)) {
      final inset = _tester.view.viewInsets.bottom;
      if (hide ? inset == 0 : inset > 0) {
        // Let the animation finish before Flutter settles.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        if (_tester.view.viewInsets.bottom == inset) return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    debugPrint('brandify: keyboard did not ${hide ? 'hide' : 'show'} within 3 s.');
  }
}
