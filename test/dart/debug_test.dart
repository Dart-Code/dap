import 'package:test/test.dart';

import '../server.dart';
import '../test_utils.dart';

void main() {
  test('Server runs a simple script in debug mode', () async {
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
        args: ['one', 'two'],
      ),
    );

    final vmConnection = outputEvents.first;
    expect(vmConnection.output,
        startsWith('Connecting to VM Service at ws://127.0.0.1:'));
    expect(vmConnection.category, equals('console'));

    final output = outputEvents.skip(1).map((e) => e.output).join();
    expectLines(output, [
      'Hello!',
      'World!',
      'args: [one, two]',
      '',
      'Exited.',
    ]);
  });
}
