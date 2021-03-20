import 'dart:async';

import 'package:dap/src/debug_protocol.dart';
import 'package:test/test.dart';

import 'server.dart';

void main() {
  test('initializeRequest', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

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
    // TODO: Test for actual desired value
    expect(result.supportsConfigurationDoneRequest, isFalse);
  });
}
