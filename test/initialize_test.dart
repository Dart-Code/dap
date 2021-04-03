import 'package:dap/src/debug_protocol.dart';
import 'package:test/test.dart';

import 'server.dart';

void main() {
  test('Server responds to initializeRequest', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    final response = await client.sendRequest('initialize', InitializeArgs());

    expect(response.success, isTrue);
    expect(response.command, equals('initialize'));
    final result = InitializeResponse.fromBody(response.body);

    // TODO(dantup): Test for actual desired value
    expect(result.supportsConfigurationDoneRequest, isTrue);
  });

  test('Server sends initialized event after handling initializeRequest',
      () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    // Collect the response + events in the order they arrive to ensure the
    // response comes before the event.
    final messages = <ProtocolMessage>[];
    await Future.wait([
      client.sendRequest('initialize', InitializeArgs()).then(messages.add),
      client.event('initialized').then(messages.add),
    ]);

    expect(messages[0], TypeMatcher<Response>());
    expect(messages[1], TypeMatcher<Event>());
  });
}
