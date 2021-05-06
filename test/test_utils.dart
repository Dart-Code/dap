import 'dart:io';
import 'dart:isolate';

import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'client.dart';

final Future<String> logsDirectory = (() async => path.join(
    path.dirname(path.dirname(
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath())),
    'logs'))();

final Future<String> testApplicationsDirectory = (() async => path.join(
    path.dirname(path.dirname(
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath())),
    'test',
    'test_applications'))();

Future<File> createTestFile(String content) async {
  final testAppDir = await testApplicationsDirectory;
  Directory(testAppDir).createSync();
  final testFile = File(path.join(testAppDir, 'automated_test_file.dart'));
  testFile.writeAsStringSync(content);
  return testFile;
}

/// Expects [actual] to equal the lines [expected], ignoring differences in line
/// endings.
void expectLines(String actual, List<String> expected) {
  expect(actual.replaceAll('\r\n', '\n'), equals(expected.join('\n')));
}

int lineWith(File file, String searchText) =>
    file.readAsLinesSync().indexWhere((line) => line.contains(searchText)) + 1;

extension DapTestClientExtensions on DapTestClient {
  /// Expects a 'stopped' event for [reason].
  ///
  /// If [file] or [line] are provided, they will be checked against the stop
  /// location for the top stack frame.
  Future<StoppedEventBody> expectedStop(String reason,
      {File? file, int? line}) async {
    final e = await event('stopped');
    final stop = StoppedEventBody.fromJson(e.body as Map<String, Object?>);
    expect(stop.reason, equals(reason));

    final response =
        await stackTrace(stop.threadId!, startFrame: 0, numFrames: 1);
    expect(response.success, isTrue);
    expect(response.command, equals('stackTrace'));
    final result =
        StackTraceResponseBody.fromJson(response.body as Map<String, Object?>);
    expect(result.stackFrames, hasLength(1));
    final frame = result.stackFrames[0];

    if (file != null) {
      expect(frame.source!.path, equals(file.path));
    }
    if (line != null) {
      expect(frame.line, equals(line));
    }

    return stop;
  }

  /// Sets a breakpoint at [line] in [file] and expects to hit it after running
  /// the script.
  Future<StoppedEventBody> hitBreakpoint(File file, int line) async {
    final stop = expectedStop('breakpoint', file: file, line: line);

    await Future.wait([
      initialize(),
      sendRequest(
        SetBreakpointsArguments(
            source: Source(path: file.path),
            breakpoints: [SourceBreakpoint(line: line)]),
      ),
      launch(file.path),
    ], eagerError: true);

    return stop;
  }
}
