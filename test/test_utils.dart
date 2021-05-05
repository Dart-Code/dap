import 'dart:io';
import 'dart:isolate';

import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

import 'client.dart';

final eol = Platform.isWindows ? '\r\n' : '\n';

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

int lineWith(File file, String searchText) =>
    file.readAsLinesSync().indexWhere((line) => line.contains(searchText));

extension DapTestClientExtensions on DapTestClient {
  Future expectedStopped(StoppedEventBody stop, String reason,
      File expectedFile, int expectedLine) async {
    expect(stop.reason, equals(reason));

    final response =
        await stackTrace(stop.threadId!, startFrame: 0, numFrames: 1);
    expect(response.success, isTrue);
    expect(response.command, equals('stackTrace'));
    final result =
        StackTraceResponseBody.fromJson(response.body as Map<String, Object?>);
    expect(result.stackFrames, hasLength(1));
    final frame = result.stackFrames[0];
    expect(frame.source!.path, equals(expectedFile.path));
    expect(frame.line, equals(expectedLine));
  }
}
