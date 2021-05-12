import 'package:test/test.dart';

import '../server.dart';
import '../test_utils.dart';

void main() {
  test('Server runs a simple script in noDebug mode', () async {
    final da = await DapTestServer.forEnvironment();
    final client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  print('Hello!');
  print('World!');
  print('args: $args');
}
    ''');

    final outputEvents = await client.collectOutput(
      launch: () => client.launch(
        testFile.path,
        noDebug: true,
        args: ['one', 'two'],
      ),
    );

    final output = outputEvents.map((e) => e.output).join();
    expectLines(output, [
      'Hello!',
      'World!',
      'args: [one, two]',
      '',
      'Exited.',
    ]);
  });

  // TODO(dantup): Does not stop at breakpoint
  // TODO(dantup): Does not stop on exception
}
