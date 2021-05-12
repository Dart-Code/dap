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

  test('stops at a line breakpoint', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    await client.hitBreakpoint(testFile, breakpointLine);
  });

  test('stops at a line breakpoint and can be resumed', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    // Hit the initial breakpoint.
    final stop = await client.hitBreakpoint(testFile, breakpointLine);

    // Resume and expect termination (as the script will get to the end).
    await Future.wait([
      client.event('terminated'),
      client.continue_(stop.threadId!),
    ], eagerError: true);
  });

  test('stops at a line breakpoint and can step over (next)', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  print('Hello!'); // BREAKPOINT
  print('Hello!'); // STEP
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');
    final stepLine = lineWith(testFile, '// STEP');

    // Hit the initial breakpoint.
    final stop = await client.hitBreakpoint(testFile, breakpointLine);

    // Step and expect stopping on the next line with a 'step' stop type.
    await Future.wait([
      client.expectStop('step', file: testFile, line: stepLine),
      client.stepIn(stop.threadId!),
    ], eagerError: true);
  });

  test('stops at a line breakpoint and can step in', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  log('Hello!'); // BREAKPOINT
}

void log(String message) { // STEP
  print(message);
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');
    final stepLine = lineWith(testFile, '// STEP');

    // Hit the initial breakpoint.
    final stop = await client.hitBreakpoint(testFile, breakpointLine);

    // Step and expect stopping in the inner function with a 'step' stop type.
    await Future.wait([
      client.expectStop('step', file: testFile, line: stepLine),
      client.stepIn(stop.threadId!),
    ], eagerError: true);
  });

  test('stops at a line breakpoint and can step out', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  log('Hello!');
  log('Hello!'); // STEP
}

void log(String message) {
  print(message); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');
    final stepLine = lineWith(testFile, '// STEP');

    // Hit the initial breakpoint.
    final stop = await client.hitBreakpoint(testFile, breakpointLine);

    // Step and expect stopping in the inner function with a 'step' stop type.
    await Future.wait([
      client.expectStop('step', file: testFile, line: stepLine),
      client.stepOut(stop.threadId!),
    ], eagerError: true);
  });

  test('does not step into SDK code with debugSdkLibraries=false', () {},
      skip: true);

  test('steps into SDK code with debugSdkLibraries=true', () {}, skip: true);

  test(
      'does not step into external package code with debugExternalPackageLibraries=false',
      () {},
      skip: true);

  test(
      'steps into external package code with debugExternalPackageLibraries=true',
      () {},
      skip: true);

  test('allows changing debug settings during session', () {
    // TODO(dantup): !
    // Dart-Code's DAP has a custom method that allows an editor to change
    // the debug settings (debugSdkLibraries/debugExternalPackageLibraries)
    // during a debug session.
  }, skip: true);
}
