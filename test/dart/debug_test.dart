import 'dart:io';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../server.dart';
import '../test_utils.dart';

void main() {
  test('Server runs a simple script in debug mode', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;
    final outputEventsFuture = client
        .events('output')
        .map((e) => OutputEventBody.fromJson(e.body as Map<String, Object?>))
        .toList();

    // Initialize.
    await Future.wait([
      client.event('initialized'),
      client.sendRequest('initialize', initArgs),
    ]);
    await client.sendRequest('configurationDone', ConfigurationDoneArguments());

    // Launch script and wait for termination.
    await Future.wait([
      client.event('terminated'),
      client.sendRequest(
        'launch',
        DartLaunchRequestArguments(
          program: 'hello_world.dart',
          cwd: await testApplicationsDirectory,
          args: ['one', 'two'],
          dartSdkPath: path.dirname(path.dirname(Platform.resolvedExecutable)),
        ),
      )
    ]);

    // Check expected output events were recieved.
    final outputEvents = await outputEventsFuture;

    final vmConnection = outputEvents.first;
    expect(vmConnection.output,
        startsWith('Connecting to VM Service at ws://127.0.0.1:'));
    expect(vmConnection.category, equals('console'));

    final output = outputEvents.skip(1).map((e) => e.output).join();
    expect(
        output,
        equals([
          'Hello!',
          'World!',
          'args: [one, two]',
          '',
          'Exited.',
        ].join(eol)));
  });
}
