import 'package:brandify_flutter/brandify_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseLocaleTag', () {
    expect(parseLocaleTag('en-US'), const Locale('en', 'US'));
    expect(parseLocaleTag('de'), const Locale('de'));
    expect(parseLocaleTag('zh-Hans'),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans'));
    expect(parseLocaleTag('zh-Hans-CN'),
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hans', countryCode: 'CN'));
    expect(parseLocaleTag('es-419'), const Locale('es', '419'));
  });
}
