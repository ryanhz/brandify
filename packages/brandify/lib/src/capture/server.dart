import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../png.dart';
import '../process.dart';

/// Version of the HTTP protocol between this server and the
/// `brandify_flutter` test helper. Keep in sync with
/// `packages/brandify_flutter/lib/src/host_client.dart`.
const captureProtocolVersion = 1;

final _shotName = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

class ShotRecord {
  ShotRecord({
    required this.name,
    required this.file,
    required this.width,
    required this.height,
    required this.attempts,
    required this.stable,
    required this.milliseconds,
  });
  final String name;
  final String file;
  final int width;
  final int height;
  final int attempts;
  final bool stable;
  final int milliseconds;

  Map<String, Object?> toJson() => {
        'name': name,
        'file': file,
        'width': width,
        'height': height,
        'attempts': attempts,
        'stable': stable,
        'ms': milliseconds,
      };
}

class CapturedPng {
  CapturedPng(this.png, {required this.attempts, required this.stable});
  final Uint8List png;
  final int attempts;
  final bool stable;
}

/// Host side of the capture handshake.
///
/// The test running on the device calls, in order:
/// - `POST /hello?run=<id>&v=<protocol>&dpr=<ratio>&w=<px>&h=<px>` once
///   (`dpr`, `w`, `h`: the app's view, recorded in the manifest),
/// - `POST /shot?run=<id>&name=<name>` per screenshot. The server captures
///   the screen and answers only once `<outDir>/<name>.png` is written, so the
///   test can't move on early,
/// - `POST /done?run=<id>` at the end.
///
/// Requests with another run ID get 409, so a stale test from an earlier run
/// can't write into this one.
class CaptureServer {
  CaptureServer._(this._server, this.runId, this.outDir, this._capture,
      this._onEvent);

  static Future<CaptureServer> start({
    required int port,
    required String runId,
    required String outDir,
    required Future<CapturedPng> Function() capture,
    void Function(String message)? onEvent,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    } on SocketException catch (e) {
      throw BrandifyException(
          'Could not listen on 127.0.0.1:$port (${e.osError?.message ?? e.message}). '
          'Is another brandify run active? Change capture.port in brandify.yaml.');
    }
    final s = CaptureServer._(server, runId, outDir, capture, onEvent ?? (_) {});
    s._serve();
    return s;
  }

  final HttpServer _server;
  final String runId;
  final String outDir;
  final Future<CapturedPng> Function() _capture;
  final void Function(String) _onEvent;

  int get port => _server.port;
  bool helloReceived = false;

  /// The app's view as the test reported it in `/hello`: `dpr` (device
  /// pixel ratio) and physical `width`/`height`. Null if not reported.
  Map<String, Object?>? view;
  final shots = <ShotRecord>[];
  final _done = Completer<void>();

  /// Completes when the test calls `/done`.
  Future<void> get done => _done.future;
  bool get isDone => _done.isCompleted;

  Future<void> _queue = Future.value();

  void _serve() {
    _server.listen((req) {
      // Handle one request at a time: captures must not overlap.
      _queue = _queue.then((_) => _handle(req));
    });
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await req.drain<void>();
      final q = req.uri.queryParameters;
      if (req.method != 'POST') {
        return await _reply(req, 405, {'error': 'use POST'});
      }
      if (q['run'] != runId) {
        return await _reply(req, 409, {
          'error': 'run ID mismatch: this test was not started by the current '
              'brandify capture run.'
        });
      }
      switch (req.uri.path) {
        case '/hello':
          final v = int.tryParse(q['v'] ?? '');
          if (v != captureProtocolVersion) {
            return await _reply(req, 409, {
              'error': 'brandify_flutter speaks protocol v$v but the brandify CLI '
                  'speaks v$captureProtocolVersion. Use matching versions of both packages.'
            });
          }
          helloReceived = true;
          final dpr = double.tryParse(q['dpr'] ?? '');
          final w = int.tryParse(q['w'] ?? ''), h = int.tryParse(q['h'] ?? '');
          if (dpr != null && dpr > 0) {
            view = {'dpr': dpr, if (w != null) 'width': w, if (h != null) 'height': h};
          }
          _onEvent('test connected');
          return await _reply(req, 200, {'ok': true, 'protocol': captureProtocolVersion});
        case '/shot':
          return await _reply(req, 200, await _shot(q['name']));
        case '/done':
          _onEvent('test finished (${shots.length} shots)');
          await _reply(req, 200, {'ok': true});
          if (!_done.isCompleted) _done.complete();
          return;
        default:
          return await _reply(req, 404, {'error': 'unknown path ${req.uri.path}'});
      }
    } on _ClientError catch (e) {
      await _reply(req, 400, {'error': e.message});
    } catch (e) {
      _onEvent('capture failed: $e');
      await _reply(req, 500, {'error': '$e'});
    }
  }

  Future<Map<String, Object?>> _shot(String? name) async {
    if (!helloReceived) throw _ClientError('call /hello first');
    if (name == null || !_shotName.hasMatch(name)) {
      throw _ClientError('Invalid shot name "$name": use lowercase letters, digits, '
          '"_" or "-" (max 64), starting with a letter or digit.');
    }
    if (shots.any((s) => s.name == name)) {
      throw _ClientError('Shot "$name" was already taken in this run; names must be unique.');
    }
    final sw = Stopwatch()..start();
    final captured = await _capture();
    final file = p.join(outDir, '$name.png');
    await File(file).writeAsBytes(captured.png, flush: true);
    final size = pngSize(captured.png)!;
    final record = ShotRecord(
      name: name,
      file: '$name.png',
      width: size.width,
      height: size.height,
      attempts: captured.attempts,
      stable: captured.stable,
      milliseconds: sw.elapsedMilliseconds,
    );
    shots.add(record);
    _onEvent('shot "$name" ${size.width}x${size.height}, ${captured.attempts} captures'
        '${captured.stable ? '' : ' (NOT stable)'}, ${sw.elapsedMilliseconds} ms');
    return {'ok': true, ...record.toJson()};
  }

  Future<void> _reply(HttpRequest req, int status, Map<String, Object?> body) async {
    req.response
      ..statusCode = status
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

class _ClientError implements Exception {
  _ClientError(this.message);
  final String message;
}
