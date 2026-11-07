import 'package:brandify/brandify.dart';
import 'package:test/test.dart';

void main() {
  test('--version exits 0', () async {
    expect(await runBrandify(['--version']), 0);
  });
}
