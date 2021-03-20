import 'dart:async';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_protocol.dart';
import 'package:dap/src/debug_session.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:test/test.dart';

void main() {
  test('foo', () async {
    final stdinController = StreamController<List<int>>();
    final stdoutController = StreamController<List<int>>();

    // Start a server.
    final server = DebugSession.run(
      stdinController.stream,
      stdoutController.sink,
      DartDebugAdapter(),
    );

    // Create a client.
    final client = LspByteStreamServerChannel(
      // For the client, the servers stdout stream is out stdin.
      stdoutController.stream,
      stdinController.sink,
    );

    final initResponseCompleter = Completer<Response>();
    client.listen((message) {
      if (message is Response && message.command == 'initialize') {
        initResponseCompleter.complete(message);
      }
    });

    client.sendRequest(Request(999, 'initialize', InitializeArgs()));

    final response = await initResponseCompleter.future;
    expect(response.requestSequence, equals(999));
    expect(response.success, isTrue);
    expect(response.command, equals('initialize'));
    final result = InitializeResponse.fromBody(response.body);
    // TODO: Fix for actual desired value
    expect(result.supportsConfigurationDoneRequest, isFalse);
  });
}
