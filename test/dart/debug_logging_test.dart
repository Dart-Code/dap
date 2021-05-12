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

  test('prints messages from dart:developer log()', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
import 'dart:developer';

void main(List<String> args) async {
  log('this is a test\nacross two lines');
  log('this is a test', name: 'foo');
}
    ''');

    final outputEvents = await client.collectOutput(file: testFile);

    // Skip the first line because it's the VM Service console info.
    final output = outputEvents.skip(1).map((e) => e.output).join();
    expectLines(output, [
      '[log] this is a test',
      '      across two lines',
      '[foo] this is a test',
      '',
      'Exited.',
    ]);
  });

  test('prints exceptions and stacks from dart:developer log()', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
import 'dart:developer';

void main(List<String> args) async {
  log('error', error: UnimplementedError(), stackTrace: StackTrace.current);
}
    ''');

    final outputEvents = await client.collectOutput(file: testFile);

    // Skip the first line because it's the VM Service console info.
    final output = outputEvents.skip(1).map((e) => e.output);
    expect(
        output,
        containsAllInOrder([
          equals('[log] error\n'),
          equals('[log] UnimplementedError\n'),
          startsWith('[log] #0      main (file://'),
        ]));
  });
}
