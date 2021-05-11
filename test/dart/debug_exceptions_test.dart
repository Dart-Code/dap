import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

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

  test('provides exception pause options', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;

    final response = await client.initialize();
    final capabilities =
        Capabilities.fromJson(response.body as Map<String, Object?>);
    expect(capabilities.exceptionBreakpointFilters, hasLength(2));

    final allFilter = capabilities.exceptionBreakpointFilters![0];
    expect(allFilter.filter, equals('All'));
    expect(allFilter.label, equals('All Exceptions'));
    expect(allFilter.defaultValue, isFalse);

    final unhandledFilter = capabilities.exceptionBreakpointFilters![1];
    expect(unhandledFilter.filter, equals('Unhandled'));
    expect(unhandledFilter.label, equals('Uncaught Exceptions'));
    expect(unhandledFilter.defaultValue, isTrue);
  });

  test('stops on an uncaught exception in Unhandled mode', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  throw 'Error!';
}
    ''');
    final exceptionLine = lineWith(testFile, 'throw');

    await client.hitException(
        testFile, ExceptionPauseMode.kUnhandled, exceptionLine);
  });

  test('does not stop on an uncaught exception in None mode', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  throw 'Error!';
}
    ''');

    await Future.wait([
      client.event('terminated'),
      client.initialize(exceptionPauseMode: ExceptionPauseMode.kNone),
      client.launch(testFile.path),
    ], eagerError: true);
  });

  test('stops on a caught exception in All mode', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  try {
    throw 'Error!';
  } catch (_) {}
}
    ''');
    final exceptionLine = lineWith(testFile, 'throw');

    await client.hitException(testFile, ExceptionPauseMode.kAll, exceptionLine);
  });

  test('does not stop on a caught exception in Unhandled mode', () async {
    da = await DapTestServer.forEnvironment();
    client = da.client;
    final testFile = await createTestFile(r'''
void main(List<String> args) async {
  try {
    throw 'Error!';
  } catch (_) {}
}
    ''');

    await Future.wait([
      client.event('terminated'),
      client.initialize(exceptionPauseMode: ExceptionPauseMode.kUnhandled),
      client.launch(testFile.path),
    ], eagerError: true);
  });
}
