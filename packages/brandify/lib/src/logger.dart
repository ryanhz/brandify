import 'dart:io';

class Logger {
  Logger({this.verbose = false, IOSink? out, IOSink? err})
      : _out = out ?? stdout,
        _err = err ?? stderr;

  final bool verbose;
  final IOSink _out;
  final IOSink _err;

  void info(String message) => _out.writeln(message);

  /// Only printed with `--verbose`.
  void detail(String message) {
    if (verbose) _out.writeln('  $message');
  }

  void warn(String message) => _err.writeln('warning: $message');
  void error(String message) => _err.writeln('error: $message');
}
