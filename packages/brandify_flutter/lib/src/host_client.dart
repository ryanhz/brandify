import 'dart:convert';
import 'dart:io';

/// Keep in sync with `captureProtocolVersion` in
/// `packages/brandify/lib/src/capture/server.dart`.
const brandifyProtocolVersion = 1;

/// Talks to the `brandify capture` server on the host. On Android the
/// CLI sets up `adb reverse`; the iOS simulator shares the host loopback.
class HostClient {
  HostClient({required this.port, required this.runId});

  final int port;
  final String runId;

  Future<Map<String, Object?>> post(String path,
      [Map<String, String> query = const {}]) async {
    final uri = Uri(
      scheme: 'http',
      host: '127.0.0.1',
      port: port,
      path: path,
      queryParameters: {'run': runId, ...query},
    );
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final HttpClientResponse res;
      try {
        final req = await client.postUrl(uri);
        res = await req.close().timeout(const Duration(minutes: 2));
      } on SocketException catch (e) {
        throw StateError(
            'brandify: cannot reach the host at 127.0.0.1:$port ($e). Run this test '
            'through `brandify capture`, which starts the server and sets up port '
            'forwarding.');
      }
      final body = await res.transform(utf8.decoder).join();
      final json = (body.isEmpty ? <String, Object?>{} : jsonDecode(body))
          as Map<String, Object?>;
      if (res.statusCode != 200) {
        throw StateError('brandify host refused $path (${res.statusCode}): '
            '${json['error'] ?? body}');
      }
      return json;
    } finally {
      client.close(force: true);
    }
  }
}
