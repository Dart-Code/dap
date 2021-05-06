import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'client.dart';

final rnd = Random();

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
  final automatedTestDir = path.join(testAppDir, 'automated');
  Directory(automatedTestDir).createSync(recursive: true);
  final testFile =
      File(path.join(automatedTestDir, 'test_file_${rnd.nextInt(10000)}.dart'));
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

    final result = await getStack(stop.threadId!, startFrame: 0, numFrames: 1);
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

  /// A helper that verifies the call stack matches [expectedCallLines], a text
  /// representation built from frame names, paths, presentationHints, line/col.
  ///
  /// Only checks from [startFrame] for the number of lines provided. Additional
  /// frames beyond this are not checked.
  Future<StackTraceResponseBody> expectCallStack(
      int threadId, String expectedCallStack,
      {required int startFrame}) async {
    final expectedLines =
        expectedCallStack.trim().split('\n').map((l) => l.trim()).toList();

    final stack = await getStack(threadId,
        startFrame: startFrame, numFrames: expectedLines.length);

    // Format the frames into a simple text representation that's easy to
    // maintain in tests.
    final actual = stack.stackFrames.map((f) {
      final buffer = StringBuffer();
      final source = f.source;

      buffer.write(f.name);
      if (source != null) {
        buffer.write(' ${source.name ?? source.path}');
      }
      buffer.write(':${f.line}:${f.column}');
      if (f.presentationHint != null) {
        buffer.write(' (${f.presentationHint})');
      }

      return buffer.toString();
    });

    expect(actual.join('\n'), equals(expectedLines.join('\n')));

    return stack;
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

  Future<StackTraceResponseBody> getStack(int threadId,
      {required int startFrame, required int numFrames}) async {
    final response = await stackTrace(threadId,
        startFrame: startFrame, numFrames: numFrames);
    expect(response.success, isTrue);
    expect(response.command, equals('stackTrace'));
    return StackTraceResponseBody.fromJson(
        response.body as Map<String, Object?>);
  }
}
