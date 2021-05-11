import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';

import 'client.dart';
import 'test_utils.dart';

final testInProcess = Platform.environment['DAP_EXTERNAL'] != 'true';

abstract class DapTestServer {
  static var _logNumber = 1;

  final DapTestClient client;

  DapTestServer._(
      StreamSink<List<int>> stdin, Stream<List<int>> stdout, Logger logger)
      : client = DapTestClient(
            // For the client, input/output are reversed.
            LspByteStreamServerChannel(stdout, stdin, logger));

  void kill();

  static FutureOr<DapTestServer> forEnvironment() async {
    final logsDir = await logsDirectory;
    Directory(logsDir).createSync();

    final logFile = File(
        path.join(logsDir, 'dap_${rnd.nextInt(10000)}_${_logNumber++}.txt'));
    print('      Logging to ${logFile.path}');
    final logger = FileLogger(logFile);

    logger.log(
        'Using ${testInProcess ? 'in-process' : 'out-of-process'} debug adapter.');
    return testInProcess
        ? DapTestServer.inProcess(logger)
        : DapTestServer.outOfProcess(logger);
  }

  static FutureOr<DapTestServer> inProcess(Logger logger) =>
      _InProcess.create(logger);

  static FutureOr<DapTestServer> outOfProcess(Logger logger) =>
      _OutOfProcess.create(logger);
}

class _InProcess extends DapTestServer {
  // ignore: unused_field
  final DebugAdapter _adapter;
  _InProcess._(
      StreamSink<List<int>> stdin, Stream<List<int>> stdout, this._adapter)
      : super._(stdin, stdout, _adapter.logger);

  @override
  void kill() {}

  static FutureOr<_InProcess> create(Logger logger) {
    final stdinController = StreamController<List<int>>();
    final stdoutController = StreamController<List<int>>();

    final channel = LspByteStreamServerChannel(
      stdinController.stream,
      stdoutController.sink,
      // This is logged on the client side and doesn't need duplicating here.
      nullLogger,
    );
    final adapter = DartDebugAdapter(channel, logger);

    return _InProcess._(stdinController.sink, stdoutController.stream, adapter);
  }
}

class _OutOfProcess extends DapTestServer {
  var _isShuttingDown = false;
  final Process _process;
  _OutOfProcess._(this._process, Logger logger)
      : super._(_process.stdin, _process.stdout, logger);

  @override
  void kill() {
    _isShuttingDown = true;
    _process.kill(ProcessSignal.sigkill);
  }

  static Future<_OutOfProcess> create(Logger logger) async {
    final packageLibDirectory =
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath();
    final packageDirectory = path.dirname(path.dirname(packageLibDirectory));
    final process = await Process.start(
      Platform.resolvedExecutable,
      [path.join(packageDirectory, 'bin', 'main.dart')],
    );

    final server = _OutOfProcess._(process, logger);

    // If the server process shuts down unexpectedly with an error, throw so
    // the tests are failed.
    unawaited(process.exitCode.then((code) async {
      if (code != 0 && !server._isShuttingDown) {
        throw 'Server process terminated with code $code!';
      }
    }));

    return server;
  }
}
