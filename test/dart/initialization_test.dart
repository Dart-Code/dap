import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:test/test.dart';

import '../server.dart';

void main() {
  test('Server responds to initializeRequest', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    final response = await client.initialize();

    expect(response.success, isTrue);
    expect(response.command, equals('initialize'));
    final result = Capabilities.fromJson(response.body as Map<String, Object?>);

    // Check some of the important capabilities to ensure the request returned
    // its response correctly.
    expect(result.supportsConfigurationDoneRequest, isTrue);
    expect(result.supportsTerminateRequest, isTrue);
    expect(result.supportsEvaluateForHovers, isTrue);
  });

  test('Server rejects unknown requests', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    final response = await client.sendRequest(null,
        overrideCommand: 'notValid', allowFailure: true);
    expect(response.success, isFalse);
    expect(response.command, equals('notValid'));
    expect(response.message, contains('Unknown command: notValid'));
  });

  test('Server sends initialized event after handling initializeRequest',
      () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    // Collect the response + events in the order they arrive to ensure the
    // response comes before the event.
    final messages = <ProtocolMessage>[];
    await Future.wait([
      client.event('initialized').then(messages.add),
      client
          .sendRequest(InitializeRequestArguments(adapterID: 'test'))
          .then(messages.add),
    ], eagerError: true);

    expect(messages[0], TypeMatcher<Response>());
    expect(messages[1], TypeMatcher<Event>());
  });
}
