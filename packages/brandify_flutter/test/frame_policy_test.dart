import 'package:brandify_flutter/brandify_flutter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

// A native view (PlatformView) updates its texture in frames the engine
// schedules, not the test. Under the binding's default `fadePointers` those
// frames are dropped and the view is captured blank (seen on a real Android
// capture of the example app's chart card), so brandifyTest runs fullyLive.
void main() {
  brandifyTest('draws every engine frame while the body runs', (tester, shot) async {
    expect(IntegrationTestWidgetsFlutterBinding.instance.framePolicy,
        LiveTestWidgetsFlutterBindingFramePolicy.fullyLive);
  });
}
