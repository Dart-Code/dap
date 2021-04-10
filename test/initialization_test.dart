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

  test('Server rejects unknown requests', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    final response = await client.sendRequest('notValid', InitializeArgs());
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
      client.sendRequest('initialize', InitializeArgs()).then(messages.add),
    ]);

    expect(messages[0], TypeMatcher<Response>());
    expect(messages[1], TypeMatcher<Event>());
  });

  test('Server responds to configurationDoneRequest', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;

    await Future.wait([
      client.event('initialized'),
      client.sendRequest('initialize', InitializeArgs()),
    ]);

    final response =
        await client.sendRequest('configurationDone', ConfigurationDoneArgs());
    expect(response.success, isTrue);
  });
}
