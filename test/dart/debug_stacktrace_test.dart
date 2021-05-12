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

  test('provides the correct synchronous call stack', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) => one();

void one() => two();
void two() => three();
void three() => four();
void four() => five();

void five() {
  print('Hello!'); // BREAKPOINT
}
    ''');
    final breakpointLine = lineWith(testFile, '// BREAKPOINT');

    final stop = await client.hitBreakpoint(testFile, breakpointLine);
    final relativePath =
        path.relative(testFile.path, from: await testApplicationsDirectory);
    await client.expectCallStack(
      stop.threadId!,
      '''
      five $relativePath:9:3
      four $relativePath:6:16
      three $relativePath:5:17
      two $relativePath:4:15
      one $relativePath:3:15
      main $relativePath:1:33
      ''',
      startFrame: 0,
    );
  });

  test('marks SDK sources as external code', () {
    // TODO(dantup): !
  }, skip: true);

  test('marks external packages as external code', () {
    // TODO(dantup): !
  }, skip: true);

  test('does not mark SDK sources as external code if debugSdkLibraries=true',
      () {
    // TODO(dantup): !
  }, skip: true);

  test(
      'does not mark external packages as external code if debugExternalPackageLibraries=true',
      () {
    // TODO(dantup): !
  }, skip: true);
}
