import 'dart:io';

import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import '../client.dart';
import '../server.dart';
import '../test_utils.dart';

void main() {
  late DapTestServer da;
  late DapTestClient client;

  tearDown(() async {
    await client.terminate().then((_) => null).catchError((e, s) => null);
    await client.disconnect().then((_) => null).catchError((e, s) {});
    da.kill();
  });

  test('Server stops at a simple line breakpoint', () async {
    final testFile =
        File(path.join(await testApplicationsDirectory, 'hello_world.dart'));
    final breakpointLine = lineWith(testFile, '// BREAKPOINT1');
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final stoppedEvent = client.stoppedEvents.first;

    await client.initialize();
    await client.sendRequest(
      SetBreakpointsArguments(
          source: Source(path: testFile.path),
          breakpoints: [SourceBreakpoint(line: breakpointLine)]),
    );
    await client.launch(testFile.path);

    await client.expectedStopped(
        await stoppedEvent, 'breakpoint', testFile, breakpointLine);
  });

  test('Server stops at a simple line breakpoint and can be resumed', () async {
    final testFile =
        File(path.join(await testApplicationsDirectory, 'hello_world.dart'));
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final stoppedEvent = client.stoppedEvents.first;

    await client.initialize();
    await client.sendRequest(
      SetBreakpointsArguments(
          source: Source(path: testFile.path),
          breakpoints: [
            SourceBreakpoint(line: lineWith(testFile, '// BREAKPOINT1'))
          ]),
    );
    await client.launch(testFile.path);
    final stop = await stoppedEvent;

    expect(stop.reason, equals('breakpoint'));

    // Resume and expect termination (as the script will get to the end).
    await Future.wait([
      client.event('terminated'),
      client.continue_(stop.threadId!),
    ], eagerError: true);
  });
}
