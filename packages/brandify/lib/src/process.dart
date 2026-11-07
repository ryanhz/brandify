import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A failure the user can act on. The CLI prints [message] without a stack
/// trace and exits 1.
class BrandifyException implements Exception {
  BrandifyException(this.message);
  final String message;
  @override
  String toString() => message;
}

class CommandResult {
  CommandResult(this.exitCode, this.stdoutBytes, this.stderr);
  final int exitCode;
  final List<int> stdoutBytes;
  final String stderr;
  String get stdout => utf8.decode(stdoutBytes, allowMalformed: true);
}

/// Runs external tools (adb, emulator, xcrun, flutter). Fakeable in tests.
abstract class ProcessRunner {
  Future<CommandResult> run(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(minutes: 2),
    String? workingDirectory,
  });

  Future<Process> start(
    String executable,
    List<String> args, {
    String? workingDirectory,
  });

  /// Like [run], but throws a [BrandifyException] on a non-zero exit code.
  Future<CommandResult> checked(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(minutes: 2),
    String? workingDirectory,
  }) async {
    final r = await run(executable, args,
        timeout: timeout, workingDirectory: workingDirectory);
    if (r.exitCode != 0) {
      throw BrandifyException(
          '`${[executable, ...args].join(' ')}` failed (exit ${r.exitCode}):\n'
          '${r.stderr.trim().isEmpty ? r.stdout.trim() : r.stderr.trim()}');
    }
    return r;
  }
}

class IoProcessRunner extends ProcessRunner {
  @override
  Future<CommandResult> run(
    String executable,
    List<String> args, {
    Duration timeout = const Duration(minutes: 2),
    String? workingDirectory,
  }) async {
    final Process p;
    try {
      p = await Process.start(executable, args,
          workingDirectory: workingDirectory);
    } on ProcessException catch (e) {
      throw BrandifyException(
          'Could not run `$executable`: ${e.message}. Is it installed and on PATH?');
    }
    final out = <int>[];
    final err = StringBuffer();
    final outDone = p.stdout.forEach(out.addAll);
    final errDone =
        p.stderr.transform(utf8.decoder).forEach(err.write);
    final code = await p.exitCode.timeout(timeout, onTimeout: () {
      p.kill(ProcessSignal.sigkill);
      throw BrandifyException(
          '`${[executable, ...args].join(' ')}` timed out after ${timeout.inSeconds} s');
    });
    await Future.wait([outDone, errDone]);
    return CommandResult(code, out, err.toString());
  }

  @override
  Future<Process> start(String executable, List<String> args,
      {String? workingDirectory}) async {
    try {
      return await Process.start(executable, args,
          workingDirectory: workingDirectory);
    } on ProcessException catch (e) {
      throw BrandifyException(
          'Could not run `$executable`: ${e.message}. Is it installed and on PATH?');
    }
  }
}
