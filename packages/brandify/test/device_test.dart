import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/config.dart';
import 'package:brandify/src/device/android.dart';
import 'package:brandify/src/device/ios.dart';
import 'package:brandify/src/logger.dart';
import 'package:brandify/src/process.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fakes.dart';

final _quiet = Logger(out: _NullSink(), err: _NullSink());
final _sdk = AndroidSdk(adb: 'adb', emulator: 'emulator');
final _png = img.encodePng(img.Image(width: 2, height: 2));

CommandResult? _androidShell(String exe, List<String> a) {
  final cmd = a.join(' ');
  if (cmd.endsWith('getprop sys.boot_completed')) return ok('1\n');
  if (cmd.endsWith('getprop ro.build.version.sdk')) return ok('36\n');
  if (cmd.endsWith('getprop ro.product.model')) return ok('sdk_gphone64\n');
  if (cmd.endsWith('wm size')) return ok('Physical size: 1080x2400\n');
  if (cmd.endsWith('settings get global sysui_demo_allowed')) return ok('1\n');
  if (cmd.contains('am broadcast')) return ok('Broadcast completed: result=0\n');
  if (cmd.endsWith('exec-out screencap -p')) return ok(_png);
  return null;
}

void main() {
  group('Android SDK discovery', () {
    test('env vars first, then the default folders', () {
      expect(AndroidSdk.sdkCandidates({'ANDROID_SDK_ROOT': '/r', 'ANDROID_HOME': '/h', 'HOME': '/u'}),
          ['/h', '/r', p.join('/u', 'Library', 'Android', 'sdk'), p.join('/u', 'Android', 'Sdk')]);
      expect(AndroidSdk.sdkCandidates({'ANDROID_HOME': '', 'HOME': '/u'}).first,
          p.join('/u', 'Library', 'Android', 'sdk'));
    });

    test('finds the SDK in ~/Library/Android/sdk with no env var set', () {
      final home = Directory.systemTemp.createTempSync('brandify_home');
      addTearDown(() => home.deleteSync(recursive: true));
      final sdk = p.join(home.path, 'Library', 'Android', 'sdk');
      File(p.join(sdk, 'platform-tools', 'adb')).createSync(recursive: true);
      File(p.join(sdk, 'emulator', 'emulator')).createSync(recursive: true);
      final found = AndroidSdk.locate({'HOME': home.path});
      expect(found.adb, p.join(sdk, 'platform-tools', 'adb'));
      expect(found.emulator, p.join(sdk, 'emulator', 'emulator'));
      expect(AndroidSdk.locate({'HOME': p.join(home.path, 'none')}).adb, 'adb', reason: 'falls back to PATH');
    });
  });

  group('android', () {
    test('serial device: demo mode with mobile hidden, adb reverse, teardown restores', () async {
      final r = FakeRunner([
        (e, a) => a.first == 'devices' ? ok('List of devices attached\nR58N\tdevice\n') : null,
        _androidShell,
      ]);
      final d = AndroidDriver(AndroidDeviceConfig('phone', serial: 'R58N'),
          runner: r, logger: _quiet, sdk: _sdk, quietInterval: Duration.zero);
      final s = await d.prepare(port: 47123);
      expect(s.flutterDeviceId, 'R58N');
      expect(s.info['api'], 36);
      expect(s.info['screen'], '1080x2400');
      final all = r.calls.join('\n');
      expect(all, contains('-e command network -e mobile hide'));
      expect(all, contains('-e command clock -e hhmm 0941'));
      expect(all, isNot(contains('datatype')));
      expect(r.calls, contains('adb -s R58N reverse tcp:47123 tcp:47123'));

      r.calls.clear();
      await s.teardown();
      expect(r.calls, contains('adb -s R58N reverse --remove tcp:47123'));
      expect(r.calls.join('\n'), contains('-e command exit'));
      expect(r.calls.join('\n'), isNot(contains('emu kill')));
    });

    test('missing serial lists connected devices', () async {
      final r = FakeRunner([(e, a) => ok('List of devices attached\nemulator-5554\tdevice\n')]);
      final d = AndroidDriver(AndroidDeviceConfig('phone', serial: 'R58N'),
          runner: r, logger: _quiet, sdk: _sdk, quietInterval: Duration.zero);
      expect(
          () => d.prepare(port: 1),
          throwsA(isA<BrandifyException>()
              .having((e) => e.message, 'm', contains('Connected: emulator-5554'))));
    });

    test('reuses a running emulator with the right AVD', () async {
      final r = FakeRunner([
        (e, a) => a.first == 'devices'
            ? ok('List of devices attached\nemulator-5554\tdevice\nemulator-5556\tdevice\n')
            : null,
        (e, a) => a.join(' ') == '-s emulator-5554 emu avd name' ? ok('Other\nOK\n') : null,
        (e, a) => a.join(' ') == '-s emulator-5556 emu avd name' ? ok('my_avd\nOK\n') : null,
        _androidShell,
      ]);
      final s = await AndroidDriver(AndroidDeviceConfig('p', avd: 'my_avd'),
              runner: r, logger: _quiet, sdk: _sdk, quietInterval: Duration.zero)
          .prepare(port: 5);
      expect(s.serial, 'emulator-5556');
      expect(r.started, isEmpty);
    });

    test('boots an AVD on a free port and kills it on teardown', () async {
      final emu = FakeProcess(body: (p) => Future<int>.delayed(const Duration(days: 1), () => 0));
      final r = FakeRunner([
        (e, a) => a.first == 'devices' ? ok('List of devices attached\nemulator-5554\tdevice\n') : null,
        (e, a) => a.contains('avd') && a.contains('name') ? ok('Other\nOK\n') : null,
        (e, a) => a.contains('kill') ? (emu..kill(), ok()).$2 : null,
        _androidShell,
      ]);
      r.onStart = (e, a) => emu;
      final s = await AndroidDriver(AndroidDeviceConfig('p', avd: 'new_avd', emulatorArgs: ['-gpu', 'host']),
              runner: r, logger: _quiet, sdk: _sdk, pollInterval: Duration.zero, quietInterval: Duration.zero)
          .prepare(port: 5);
      expect(s.serial, 'emulator-5556');
      expect(r.started.single,
          'emulator -avd new_avd -port 5556 -no-window -no-audio -no-boot-anim -no-snapshot-save -gpu host');
      await s.teardown();
      expect(r.calls, contains('adb -s emulator-5556 emu kill'));
      expect(emu.killed, isTrue);
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('an emulator that exits early reports its output', () async {
      final r = FakeRunner([
        (e, a) => a.first == 'devices' ? ok('List of devices attached\n') : null,
        (e, a) => a.contains('sys.boot_completed') ? failed('device offline') : null,
      ]);
      r.onStart = (e, a) => FakeProcess(body: (p) async {
            p.writeln('PANIC: Unknown AVD name [nope]');
            return 1;
          });
      final d = AndroidDriver(AndroidDeviceConfig('p', avd: 'nope'),
          runner: r, logger: _quiet, sdk: _sdk, pollInterval: const Duration(milliseconds: 10));
      expect(
          () => d.prepare(port: 5),
          throwsA(isA<BrandifyException>()
              .having((e) => e.message, 'm', contains('PANIC: Unknown AVD name'))));
    });
  });

  group('ios', () {
    final json = jsonEncode({
      'devices': {
        'com.apple.CoreSimulator.SimRuntime.iOS-18-2': [
          {'udid': 'OLD', 'name': 'iPhone 16 Pro Max', 'state': 'Shutdown', 'isAvailable': true},
        ],
        'com.apple.CoreSimulator.SimRuntime.iOS-26-0': [
          {'udid': 'NEW', 'name': 'iPhone 16 Pro Max', 'state': 'Shutdown', 'isAvailable': true},
          {'udid': 'X', 'name': 'iPhone 17 Pro Max', 'state': 'Booted', 'isAvailable': true},
        ],
        'com.apple.CoreSimulator.SimRuntime.watchOS-11-0': [
          {'udid': 'W', 'name': 'Apple Watch', 'state': 'Shutdown', 'isAvailable': true},
        ],
      }
    });

    test('resolves by name: newest runtime, booted first', () {
      final all = parseSimctlDevices(json);
      expect(resolveSimulator(IosDeviceConfig('a', simulator: 'iPhone 16 Pro Max'), all).udid, 'NEW');
      expect(resolveSimulator(IosDeviceConfig('a', udid: 'OLD'), all).udid, 'OLD');
      expect(
          () => resolveSimulator(IosDeviceConfig('a', simulator: 'iPhone 99'), all),
          throwsA(isA<BrandifyException>().having((e) => e.message, 'm',
              allOf(contains('iPhone 17 Pro Max'), isNot(contains('Apple Watch'))))));
    });

    test('boots, overrides status bar, shuts down what it booted', () async {
      final r = FakeRunner([(e, a) => a.contains('list') ? ok(json) : null]);
      final d = IosDriver(IosDeviceConfig('i', simulator: 'iPhone 16 Pro Max'),
          runner: r, logger: _quiet, isMacOS: true);
      final s = await d.prepare(port: 47123);
      expect(s.flutterDeviceId, 'NEW');
      expect(r.calls, contains('xcrun simctl boot NEW'));
      expect(r.calls.join('\n'), contains('status_bar NEW override --time 9:41'));
      expect(r.calls.join('\n'), isNot(contains('reverse')));
      await s.teardown();
      expect(r.calls, containsAll(['xcrun simctl status_bar NEW clear', 'xcrun simctl shutdown NEW']));
    });

    test('a booted simulator is reused and left running', () async {
      final r = FakeRunner([(e, a) => a.contains('list') ? ok(json) : null]);
      final s = await IosDriver(IosDeviceConfig('i', simulator: 'iPhone 17 Pro Max'),
              runner: r, logger: _quiet, isMacOS: true)
          .prepare(port: 1);
      await s.teardown();
      expect(r.calls.where((c) => c.contains(' boot ') || c.contains('shutdown')), isEmpty);
    });

    test('refuses on non-macOS', () {
      final d = IosDriver(IosDeviceConfig('i', simulator: 'x'),
          runner: FakeRunner(), logger: _quiet, isMacOS: false);
      expect(() => d.prepare(port: 1),
          throwsA(isA<BrandifyException>().having((e) => e.message, 'm', contains('macOS'))));
    });
  });
}

class _NullSink implements IOSink {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
