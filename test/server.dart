import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_packet_transformer.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';

import 'client.dart';
import 'test_utils.dart';

final dapClientType = dapServerPort != null
    ? DapMode.externalPort
    : Platform.environment['DAP_EXTERNAL'] == 'true'
        ? DapMode.externalStdin
        : DapMode.internal;
final dapServerPort = int.tryParse(Platform.environment['DAP_EXTERNAL'] ?? '');

enum DapMode {
  /// Connect to a server that is running in-process for easier debugging.
  internal,

  /// Connect to an external DAP process running over stdin/stdout in single-
  /// session mode.
  externalStdin,

  /// Connect to an external DAP process listening on a port in multi-session
  /// mode.
  externalPort,
}

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

    logger.log('Using $dapClientType debug adapter.');
    switch (dapClientType) {
      case DapMode.internal:
        return _InProcess.create(logger);
      case DapMode.externalStdin:
        return _OutOfProcessStdin.create(logger);
      case DapMode.externalPort:
        return _OutOfProcessPort.create(dapServerPort!, logger);
    }
  }
}

/// An in-process instance of the debug adapter that can be easily debugged in
/// tests.
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

/// A connection to an out-of-process debug adapter running in multi-session
/// mode. The server is expected to be already running.
class _OutOfProcessPort extends DapTestServer {
  var _isShuttingDown = false;
  _OutOfProcessPort._(
      StreamSink<List<int>> stdin, Stream<List<int>> stdout, Logger logger)
      : super._(stdin, stdout, logger);

  @override
  void kill() {
    _isShuttingDown = true;
  }

  static Future<_OutOfProcessPort> create(int port, Logger logger) async {
    await Future.delayed(Duration(seconds: 2));
    final socket = await Socket.connect('localhost', port);
    final server = _OutOfProcessPort._(
        socket, socket.transform(Uint8ListTransformer()), logger);

    // If the server process shuts down unexpectedly with an error, throw so
    // the tests are failed.
    unawaited(socket.done.then((_) async {
      if (!server._isShuttingDown) {
        throw 'Connection terminated!';
      }
    }));

    return server;
  }
}

/// An out-of-process instance of the debug adapter running in single-session
/// (stdin/stdout) more.
class _OutOfProcessStdin extends DapTestServer {
  var _isShuttingDown = false;
  final Process _process;
  _OutOfProcessStdin._(this._process, Logger logger)
      : super._(_process.stdin, _process.stdout, logger);

  @override
  void kill() {
    _isShuttingDown = true;
    _process.kill(ProcessSignal.sigkill);
  }

  static Future<_OutOfProcessStdin> create(Logger logger) async {
    final packageLibDirectory =
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath();
    final packageDirectory = path.dirname(path.dirname(packageLibDirectory));
    final process = await Process.start(
      Platform.resolvedExecutable,
      [path.join(packageDirectory, 'bin', 'main.dart')],
    );

    final server = _OutOfProcessStdin._(process, logger);

    process.stderr.listen((data) {
      final message = 'DA wrote to stderr: ${String.fromCharCodes(data)}';
      print(message);
      throw Exception(message);
    });

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
