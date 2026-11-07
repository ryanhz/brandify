import 'dart:io';

import 'package:brandify/brandify.dart';

Future<void> main(List<String> args) async {
  exitCode = await runBrandify(args);
}
