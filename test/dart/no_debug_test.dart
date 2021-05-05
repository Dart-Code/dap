import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../server.dart';
import '../test_utils.dart';

void main() {
  test('Server runs a simple script in noDebug mode', () async {
    final testFile =
        File(path.join(await testApplicationsDirectory, 'hello_world.dart'));
    final da = await DapTestServer.forEnvironment();
    final client = da.client;
    final outputEventsFuture = client.outputEvents.toList();

    // Initialize.
    await client.initialize();

    // Launch script and wait for termination.
    await Future.wait([
      client.event('terminated'),
      client.launch(testFile.path, noDebug: true, args: ['one', 'two'])
    ], eagerError: true);

    // Check expected output events were recieved.
    final outputEvents = await outputEventsFuture;

    final output = outputEvents.map((e) => e.output).join();
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
