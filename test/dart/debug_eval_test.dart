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

  test('evaluates simple expressions', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  var a = 1;
  var b = 2;
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    final stop = await client.hitBreakpoint(testFile, breakpointLine);
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    await client.expectEvalResult(topFrameId, 'a', '1');
    await client.expectEvalResult(topFrameId, 'a.toString()', '"1"');
    await client.expectEvalResult(topFrameId, 'a * b', '2');
  });

  test('evaluates complex expressions expressions', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    final stop = await client.hitBreakpoint(testFile, breakpointLine);
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    final result = await client.expectEvalResult(
        topFrameId, 'DateTime(2000, 1, 1)', 'DateTime');
    expect(result.variablesReference, greaterThan(0));

    // Ensure the variablesReference is valid.
    final variable = await client.variables(result.variablesReference);
    expect(variable.success, true);
  });

  test(
      'evaluates complex expressions expressions with evaluateToStringInDebugViews=true',
      () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    final stop = await client.hitBreakpoint(testFile, breakpointLine,
        launch: () =>
            client.launch(testFile.path, evaluateToStringInDebugViews: true));
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    final result = await client.expectEvalResult(topFrameId,
        'DateTime(2000, 1, 1)', 'DateTime (2000-01-01 00:00:00.000)');
    expect(result.variablesReference, greaterThan(0));

    // Ensure the variablesReference is valid.
    final variable = await client.variables(result.variablesReference);
    expect(variable.success, true);
  });

  test(r'evaluates $e to the threads exception (simple type)', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  throw 'my error';
}
    ''');

    final stop = await client.hitException(testFile);
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    final result =
        await client.expectEvalResult(topFrameId, r'$e', '"my error"');
    expect(result.variablesReference, equals(0));
  });

  test(r'evaluates $e to the threads exception (complex type)', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  throw Exception('my error');
}
    ''');

    final stop = await client.hitException(testFile);
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    final result =
        await client.expectEvalResult(topFrameId, r'$e', '_Exception');
    expect(result.variablesReference, greaterThan(0));
  });

  test(r'evaluates $e.x.y to x.y on the threads exception', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  throw Exception('12345');
}
    ''');

    final stop = await client.hitException(testFile);
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    final result =
        await client.expectEvalResult(topFrameId, r'$e.message.length', '5');
    expect(result.variablesReference, equals(0));
  });
}
