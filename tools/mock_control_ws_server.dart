import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final host = Platform.environment['OPENRD_MOCK_WS_HOST'] ?? '0.0.0.0';
  final port = int.parse(Platform.environment['OPENRD_MOCK_WS_PORT'] ?? '8080');
  final path = Platform.environment['OPENRD_MOCK_WS_PATH'] ?? '/control';
  final server = await HttpServer.bind(host, port);
  var clientCount = 0;

  stdout.writeln(
    'OpenRD mock control WebSocket listening on ws://$host:$port$path',
  );
  await for (final request in server) {
    if (request.uri.path != path) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      continue;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      continue;
    }

    final socket = await WebSocketTransformer.upgrade(request);
    clientCount += 1;
    final clientId = clientCount;
    stdout.writeln(
      '[$clientId] connected from ${request.connectionInfo?.remoteAddress.address}',
    );
    socket.add(
      jsonEncode(<String, Object>{
        'type': 'hello',
        'client': clientId,
        'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    );

    socket.listen(
      (data) {
        final text = data.toString();
        stdout.writeln('[$clientId] rx $text');
        socket.add(
          jsonEncode(<String, Object>{
            'type': 'ack',
            'client': clientId,
            'timestamp_ms': DateTime.now().millisecondsSinceEpoch,
            'echo': text,
          }),
        );
      },
      onDone: () {
        stdout.writeln('[$clientId] disconnected');
      },
      onError: (Object error) {
        stderr.writeln('[$clientId] error: $error');
      },
    );
  }
}
