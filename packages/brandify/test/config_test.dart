import 'package:brandify/src/config.dart';
import 'package:test/test.dart';

BrandifyConfig parse(String yaml) => BrandifyConfig.parse(yaml, root: '/proj');

Matcher throwsConfig(String fragment) =>
    throwsA(isA<ConfigException>().having((e) => e.message, 'message', contains(fragment)));

void main() {
  test('parses a full config with defaults', () {
    final c = parse('''
locales: [en-US, zh-Hans]
devices:
  - {id: pixel, platform: android, avd: Pixel_8, emulator_args: [-gpu, host]}
  - {id: ipad, platform: ios, simulator: "iPad Pro 13-inch (M4)"}
''');
    expect(c.locales, ['en-US', 'zh-Hans']);
    final a = c.devices[0] as AndroidDeviceConfig;
    expect(a.avd, 'Pixel_8');
    expect(a.emulatorArgs, ['-gpu', 'host']);
    expect((c.devices[1] as IosDeviceConfig).simulator, 'iPad Pro 13-inch (M4)');
    expect(c.capture.port, 47123);
    expect(c.capture.test, 'integration_test/brandify_test.dart');
    expect(c.outputDir, '/proj/build/brandify/raw');
  });

  test('capture overrides', () {
    final c = parse('''
locales: [en-US]
devices: [{id: p, platform: android, serial: emulator-5554}]
capture: {port: 50000, stable_max_attempts: 4, stable_interval_ms: 0, output: shots}
''');
    expect(c.capture.port, 50000);
    expect(c.capture.stableMaxAttempts, 4);
    expect(c.capture.stableInterval, Duration.zero);
    expect(c.outputDir, '/proj/shots');
  });

  test('frame defaults and full form', () {
    final d = parse('locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]');
    expect(d.frame.device, FrameDeviceStyle.screen);
    expect(d.frame.template, FrameTemplate.captionTop);
    expect(d.frame.captionArea, isNull);
    expect(d.frame.captions, isEmpty);
    expect(d.framedDir, '/proj/build/brandify/framed');

    final c = parse('''
locales: [en-US, de-DE]
devices: [{id: p, platform: android, avd: a}]
frame:
  output: out/framed
  template: caption_top
  caption_area: 0.3
  background: ['#0B1F3A', '#802E5BFF']
  device: bezel
  font: fonts/Noto.ttf
  captions:
    en-US:
      home: Everything in one place
      add_task: {headline: Add a task, subheadline: In two taps}
''');
    expect(c.framedDir, '/proj/out/framed');
    expect(c.frame.captionArea, 0.3);
    expect(c.frame.background, [0xFF0B1F3A, 0x802E5BFF]);
    expect(c.frame.device, FrameDeviceStyle.bezel);
    expect(c.frame.font, 'fonts/Noto.ttf');
    expect(c.frame.captions['en-US']!['home']!.headline, 'Everything in one place');
    expect(c.frame.captions['en-US']!['add_task']!.subheadline, 'In two taps');
    expect(parse('locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\nframe: {background: "#FFFFFF"}')
        .frame.background, [0xFFFFFFFF]);
  });

  test('frame errors', () {
    const base = 'locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\n';
    expect(() => parse('${base}frame: {background: red}'), throwsConfig('"#RRGGBB"'));
    expect(() => parse('${base}frame: {device: tilted}'), throwsConfig('`screen` or `bezel`'));
    expect(() => parse('${base}frame: {template: bleed}'), throwsConfig('Available: caption_top'));
    expect(() => parse('${base}frame: {caption_area: 0.9}'), throwsConfig('between 0.05 and 0.6'));
    expect(() => parse('${base}frame: {caption_area: big}'), throwsConfig('between 0.05 and 0.6'));
    expect(parse('${base}frame: {caption_area: auto}').frame.captionArea, isNull);
    expect(() => parse('${base}frame: {status_bar: true}'), throwsConfig('Unknown key `status_bar`'));
    expect(() => parse('${base}frame: {captions: {fr-FR: {home: Salut}}}'), throwsConfig('not in `locales`'));
    expect(() => parse('${base}frame: {captions: {en-US: {home: {title: Hi}}}}'), throwsConfig('Unknown key `title`'));
  });

  test('errors point at the problem', () {
    expect(() => parse('locales: [en-US]\ndevices: []\nfoo: 1'), throwsConfig('Unknown key `foo`'));
    expect(() => parse('locales: [english]\ndevices: []'), throwsConfig('Invalid locale "english"'));
    expect(() => parse('locales: [en-US]\ndevices: [{id: p, platform: android}]'),
        throwsConfig('exactly one of `avd`'));
    expect(
        () => parse('locales: [en-US]\ndevices: [{id: p, platform: android, avd: a, serial: b}]'),
        throwsConfig('exactly one of `avd`'));
    expect(() => parse('locales: [en-US]\ndevices: [{id: p, platform: ios}]'),
        throwsConfig('exactly one of `simulator`'));
    expect(
        () => parse('locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}, {id: p, platform: android, avd: b}]'),
        throwsConfig('Duplicate device id'));
    expect(() => parse('locales: [en-US]\ndevices: [{id: Pixel, platform: android, avd: a}]'),
        throwsConfig('lowercase'));
    expect(() => parse('locales: [en-US]\ndevices: [{id: p, platform: web, avd: a}]'),
        throwsConfig('`android` or `ios`'));
    expect(() => parse('locales: [en-US]\ndevices: [{id: p, platform: android, avd: a}]\ncapture: {port: 80}'),
        throwsConfig('between 1024'));
    expect(() => parse('devices: []'), throwsConfig('Missing `locales`'));
  });

  test('error messages include the line', () {
    expect(() => parse('locales: [en-US]\ndevices:\n  - {id: p, platform: android, avd: a, colour: red}'),
        throwsConfig('line 3'));
  });
}
