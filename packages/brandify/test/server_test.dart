import 'dart:convert';
import 'dart:io';

import 'package:brandify/src/capture/server.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<(int, Map<String, Object?>)> post(int port, String path, Map<String, String> q,
    {String method = 'POST'}) async {
  final c = HttpClient();
  try {
    final req = await c.openUrl(method,
        Uri(scheme: 'http', host: '127.0.0.1', port: port, path: path, queryParameters: q));
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return (res.statusCode, jsonDecode(body) as Map<String, Object?>);
  } finally {
    c.close();
  }
}

void main() {
  late Directory tmp;
  late CaptureServer server;
  var captures = 0;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('bp_server');
    captures = 0;
    final png = img.encodePng(img.Image(width: 6, height: 9));
    server = await CaptureServer.start(
      port: 0,
      runId: 'r1',
      outDir: tmp.path,
      capture: () async {
        captures++;
        return CapturedPng(png, attempts: 2, stable: true);
      },
    );
  });
  tearDown(() async {
    await server.close();
    await tmp.delete(recursive: true);
  });

  test('full handshake writes the PNG before answering', () async {
    final port = server.port;
    expect((await post(port, '/hello', {'run': 'r1', 'v': '$captureProtocolVersion'})).$1, 200);
    final (code, body) = await post(port, '/shot', {'run': 'r1', 'name': 'home'});
    expect(code, 200);
    expect(body['width'], 6);
    expect(body['height'], 9);
    expect(File(p.join(tmp.path, 'home.png')).existsSync(), isTrue);
    expect(server.isDone, isFalse);
    expect((await post(port, '/done', {'run': 'r1'})).$1, 200);
    await server.done;
    expect(server.shots.single.name, 'home');
  });

  test('rejects wrong run, wrong protocol, GET, shot before hello', () async {
    final port = server.port;
    expect((await post(port, '/hello', {'run': 'old', 'v': '1'})).$1, 409);
    expect((await post(port, '/hello', {'run': 'r1', 'v': '999'})).$2['error'],
        contains('protocol'));
    expect((await post(port, '/hello', {'run': 'r1', 'v': '1'}, method: 'GET')).$1, 405);
    expect((await post(port, '/shot', {'run': 'r1', 'name': 'x'})).$1, 400);
    expect(captures, 0);
  });

  test('rejects bad and duplicate names', () async {
    final port = server.port;
    await post(port, '/hello', {'run': 'r1', 'v': '1'});
    expect((await post(port, '/shot', {'run': 'r1', 'name': '../evil'})).$1, 400);
    expect((await post(port, '/shot', {'run': 'r1', 'name': 'Home'})).$1, 400);
    expect((await post(port, '/shot', {'run': 'r1', 'name': 'home'})).$1, 200);
    final (code, body) = await post(port, '/shot', {'run': 'r1', 'name': 'home'});
    expect(code, 400);
    expect(body['error'], contains('already taken'));
    expect(captures, 1);
  });
}
