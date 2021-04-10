import 'dart:io';

import 'package:dap/src/debug_adapter_protocol.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;

import 'server.dart';
import 'test_utils.dart';

void main() {
  test('Server runs a simple script in noDebug mode', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;
    final outputEvents = client
        .events('output')
        .map((e) => OutputEventBody.fromJson(e.body as Map<String, Object?>))
        .toList();

    // Initialize.
    await Future.wait([
      client.event('initialized'),
      client.sendRequest('initialize', InitializeArgs()),
    ]);
    await client.sendRequest('configurationDone', ConfigurationDoneArgs());

    // Launch script and wait for termination.
    await Future.wait([
      client.event('terminated'),
      client.sendRequest(
        'launch',
        LaunchArgs(
          program: 'hello_world.dart',
          cwd: await testApplicationsDirectory,
          args: ['one', 'two'],
          dartSdkPath: path.dirname(path.dirname(Platform.executable)),
        ),
      )
    ]);

    // Check expected output events were recieved.
    final output = (await outputEvents).map((e) => e.output).join();
    expect(
        output,
        equals(
          'Hello!\n'
          'World!\n'
          'args: [one, two]\n'
          '\nExited.',
        ));
  });
}
