import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:uuid/uuid.dart';

// Ensure these match your client's expectations
const String uuidString = 'd342d11e-d424-4583-b36e-524ab1f0afa4';
final Uint8List uuidBytes = _uuidToBytes(uuidString);
const int port = 3000;

void main() async {
  // Define a WebSocket handler
  final webSocketHandler = webSocketHandler((WebSocketChannel wsChannel) async {
    print('New WebSocket connection via Shelf');

    wsChannel.stream.listen(
      (message) async {
        if (message is! Uint8List) {
          print('Received non-binary message, closing connection.');
          wsChannel.sink.close(WebSocketStatus.unsupportedData);
          return;
        }

        final Uint8List msg = message;

        final int version = msg[0];
        final Uint8List id = msg.sublist(1, 17);

        bool uuidMatches = true;
        if (id.length != uuidBytes.length) {
          uuidMatches = false;
        } else {
          for (int i = 0; i < id.length; i++) {
            if (id[i] != uuidBytes[i]) {
              uuidMatches = false;
              break;
            }
          }
        }
        if (!uuidMatches) {
          print('UUID mismatch, closing connection.');
          wsChannel.sink.close(WebSocketStatus.policyViolation);
          return;
        }

        int offset = 17;
        final int vlessOptionsLength = msg.buffer.asByteData().getUint8(offset);
        offset += 1 + vlessOptionsLength;

        final int port = msg.buffer.asByteData().getUint16(offset, Endian.big);
        offset += 2;

        final int atyp = msg.buffer.asByteData().getUint8(offset);
        offset += 1;

        String host = '';
        if (atyp == 0x01) { // IPv4
          final List<int> ipv4Bytes = msg.sublist(offset, offset + 4);
          host = ipv4Bytes.join('.');
          offset += 4;
        } else if (atyp == 0x02) { // Domain name
          final int domainLength = msg.buffer.asByteData().getUint8(offset);
          offset += 1;
          final Uint8List domainBytes = msg.sublist(offset, offset + domainLength);
          host = utf8.decode(domainBytes);
          offset += domainLength;
        } else if (atyp == 0x03) { // IPv6
          final Uint8List ipv6Bytes = msg.sublist(offset, offset + 16);
          List<String> hexParts = [];
          for (int j = 0; j < ipv6Bytes.length; j += 2) {
            final int part = ipv6Bytes.buffer.asByteData().getUint16(j, Endian.big);
            hexParts.add(part.toRadixString(16));
          }
          host = hexParts.join(':');
          offset += 16;
        } else {
          print('Unsupported ATYP: $atyp');
          wsChannel.sink.close(WebSocketStatus.protocolError);
          return;
        }

        print('Connection request for: $host:$port');
        wsChannel.sink.add(Uint8List.fromList([version, 0]));

        try {
          final Socket targetSocket = await Socket.connect(host, port);
          print('Connected to target: $host:$port');

          final Uint8List initialTargetData = msg.sublist(offset);
          if (initialTargetData.isNotEmpty) {
            targetSocket.add(initialTargetData);
          }

          wsChannel.stream.listen(
            (data) {
              if (data is Uint8List) {
                targetSocket.add(data);
              }
            },
            onDone: () {
              print('WebSocket stream done. Closing target socket write.');
              targetSocket.destroy();
            },
            onError: (e) {
              print('WebSocket stream error: $e');
              targetSocket.destroy();
            },
            cancelOnError: true,
          );

          targetSocket.listen(
            (data) {
              wsChannel.sink.add(data);
            },
            onDone: () {
              print('Target socket done. Closing WebSocket.');
              wsChannel.sink.close();
            },
            onError: (e) {
              print('Target socket error: $e');
              wsChannel.sink.close();
            },
            cancelOnError: true,
          );
        } catch (e) {
          print('Connection to target failed: $host:$port - $e');
          wsChannel.sink.close(WebSocketStatus.internalServerError);
        }
      },
      onDone: () {
        print('WebSocket closed.');
      },
      onError: (e) {
        print('WebSocket error: $e');
      },
      cancelOnError: true,
    );
  });

  // Create a pipeline for HTTP requests (if you want other routes)
  final handler = Pipeline().addMiddleware(logRequests()).addHandler((Request request) {
    if (request.url.path == 'ws') { // Example path for WebSocket
      return webSocketHandler(request);
    }
    return Response.notFound('Not Found'); // Default for other paths
  });

  // Start the server
  final server = await io.serve(handler, InternetAddress.anyIPv4, port);
  print('Shelf WebSocket server listening on ws://${server.address.host}:${server.port}/ws');
}

Uint8List _uuidToBytes(String uuidString) {
  final cleanedUuid = uuidString.replaceAll('-', '');
  final List<int> bytes = [];
  for (int i = 0; i < cleanedUuid.length; i += 2) {
    bytes.add(int.parse(cleanedUuid.substring(i, i + 2), radix: 16));
  }
  return Uint8List.fromList(bytes);
}
