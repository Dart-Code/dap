import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_session.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';

const _debugTrace = false;

List<int> _trace(String prefix, List<int> data) {
  if (_debugTrace) {
    print('$prefix${utf8.decode(data)}');
  }
  return data;
}

abstract class DapTestServer {
  final LspByteStreamServerChannel client;

  DapTestServer._(StreamSink<List<int>> stdin, Stream<List<int>> stdout)
      // For the client, input/output are reversed.
      : client = LspByteStreamServerChannel(
          stdout.map((data) => _trace('<== ', data)),
          StreamController<List<int>>()
            ..stream.listen((data) => stdin.add(_trace('==> ', data))),
        );

  static FutureOr<DapTestServer> forEnvironment() {
    final inProc = Platform.environment['DAP_EXTERNAL'] != 'true';
    if (_debugTrace) {
      print('Using ${inProc ? 'in-process' : 'out-of-process'} debug adapter.');
    }
    return inProc ? DapTestServer.inProcess() : DapTestServer.outOfProcess();
  }

  static FutureOr<DapTestServer> inProcess() => _InProcess.create();
  static FutureOr<DapTestServer> outOfProcess() => _OutOfProcess.create();
}

class _InProcess extends DapTestServer {
  // TODO: Use this to shut down.
  // ignore: unused_field
  final DebugSession _session;
  _InProcess._(
      StreamSink<List<int>> stdin, Stream<List<int>> stdout, this._session)
      : super._(stdin, stdout);

  static FutureOr<_InProcess> create() {
    final stdinController = StreamController<List<int>>();
    final stdoutController = StreamController<List<int>>();

    final session = DebugSession.start(
      stdinController.stream,
      stdoutController.sink,
      DartDebugAdapter(),
    );

    return _InProcess._(stdinController.sink, stdoutController.stream, session);
  }
}

class _OutOfProcess extends DapTestServer {
  // TODO: Use this to shut down.
  // ignore: unused_field
  final Process _process;
  _OutOfProcess._(this._process) : super._(_process.stdin, _process.stdout);

  static Future<_OutOfProcess> create() async {
    final packageLibDirectory =
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath();
    final packageDirectory = path.dirname(path.dirname(packageLibDirectory));
    final process = await Process.start(
      Platform.executable,
      [path.join(packageDirectory, 'bin', 'main.dart')],
    );

    process.stderr.listen((data) => _trace('PROCESS: ', data));

    unawaited(process.exitCode.then((code) async {
      if (code != 0) {
        throw 'Server process terminated with code $code!';
      }
    }));

    return _OutOfProcess._(process);
  }
}
