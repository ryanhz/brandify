import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/process.dart';

typedef Handler = CommandResult? Function(String exe, List<String> args);

CommandResult ok([Object stdout = '']) => CommandResult(
    0, stdout is List<int> ? stdout : utf8.encode('$stdout'), '');
CommandResult failed([String stderr = 'error']) => CommandResult(1, const [], stderr);

/// Records every command; answers with the first handler that returns
/// non-null, else success with empty output.
class FakeRunner extends ProcessRunner {
  FakeRunner([List<Handler>? handlers]) : handlers = handlers ?? [];
  final List<Handler> handlers;
  final calls = <String>[];
  final started = <String>[];
  FakeProcess Function(String exe, List<String> args)? onStart;

  @override
  Future<CommandResult> run(String executable, List<String> args,
      {Duration timeout = const Duration(minutes: 2), String? workingDirectory}) async {
    calls.add([executable, ...args].join(' '));
    for (final h in handlers) {
      final r = h(executable, args);
      if (r != null) return r;
    }
    return ok();
  }

  @override
  Future<Process> start(String executable, List<String> args,
      {String? workingDirectory}) async {
    started.add([executable, ...args].join(' '));
    return onStart!(executable, args);
  }
}

class FakeProcess implements Process {
  FakeProcess({Future<int> Function(FakeProcess p)? body}) {
    () async {
      final code = body == null ? 0 : await body(this);
      await _out.close();
      await _err.close();
      _exit.complete(code);
    }();
  }
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  void writeln(String line) => _out.add(utf8.encode('$line\n'));

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => 1;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }
}
