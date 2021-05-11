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

  test('provides variable list for frames', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  final a = 1;
  foo();
}

void foo() {
  final b = 2;
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    final stop = await client.hitBreakpoint(testFile, breakpointLine);
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 2);

    // Check top two frames (in `foo` and in `main`).
    await client.expectScopeVariables(
      stack.stackFrames[0].id,
      'Variables',
      '''
      b: 2
      ''',
    );
    await client.expectScopeVariables(
      stack.stackFrames[1].id,
      'Variables',
      '''
      a: 1
      args: List (0 items)
      ''',
    );
  });

  test('provides exception for frames', () async {
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

    // Check for an additional Scope named "Exceptions" that includes the
    // exception.
    await client.expectScopeVariables(
      topFrameId,
      'Exceptions',
      '''
      String: "my error"
      ''',
    );
  });

  test('renders simple variable fields', () async {
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
    await client.expectVariables(
      result.variablesReference,
      '''
      isUtc: false
      ''',
    );
  });

  test('renders variable getters when evaluateGettersInDebugViews=true',
      () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) {
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    final stop = await client.hitBreakpoint(
      testFile,
      breakpointLine,
      launch: () =>
          client.launch(testFile.path, evaluateGettersInDebugViews: true),
    );
    final stack =
        await client.getStack(stop.threadId!, startFrame: 0, numFrames: 1);
    final topFrameId = stack.stackFrames.first.id;

    final result = await client.expectEvalResult(
        topFrameId, 'DateTime(2000, 1, 1)', 'DateTime');
    await client.expectVariables(
      result.variablesReference,
      '''
      day: 1
      hour: 0
      isUtc: false
      microsecond: 0
      microsecondsSinceEpoch: 946684800000000
      millisecond: 0
      millisecondsSinceEpoch: 946684800000
      minute: 0
      month: 1
      runtimeType: Type (DateTime)
      second: 0
      timeZoneOffset: Duration
      weekday: 6
      year: 2000
      ''',
      ignore: {'timeZoneName'},
    );
  });

  test('renders a simple list', () async {
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
        topFrameId, '["first", "second", "third"]', 'List (3 items)');
    await client.expectVariables(
      result.variablesReference,
      '''
      0: "first"
      1: "second"
      2: "third"
      ''',
    );
  });

  test('renders a simple list subset', () async {
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
        topFrameId, '["first", "second", "third"]', 'List (3 items)');
    await client.expectVariables(
      result.variablesReference,
      '''
      1: "second"
      ''',
      start: 1,
      count: 1,
    );
  });

  test('renders a simple map', () {
    // TODO(dantup): !
  }, skip: true);

  test('renders a simple map subset', () {
    // TODO(dantup): !
  }, skip: true);

  // TODO(dantup): $e
  // TODO(dantup): $e evaluateName (so can expand fields)
  // TODO(dantup): $e evaluateName prepended onto children?
}
