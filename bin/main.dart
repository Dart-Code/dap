import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:args/args.dart';
import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_packet_transformer.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';

void main(List<String> args) {
  final argResult = parser.parse(args);

  if (argResult.wasParsed('help')) {
    print(parser.usage);
    return;
  }

  if (argResult.wasParsed('port') && int.tryParse(argResult['port']) == null) {
    print('--port requires a valid port number\n');
    print(parser.usage);
    return;
  }
  final port =
      argResult.wasParsed('port') ? int.tryParse(argResult['port']) : null;
  final verbose = argResult.wasParsed('port') && argResult['verbose'];

  runZonedGuarded(
    () async {
      if (port != null) {
        final server = await ServerSocket.bind('localhost', port);
        print('{"event": "serverPort", "port": ${server.port}}');
        await for (final connection in server) {
          if (verbose) {
            print('Accepted connection from ${connection.remoteAddress}');
            unawaited(connection.done.then((_) {
              print('Connection from ${connection.remoteAddress} closed');
            }));
          }
          _createAdapter(connection.transform(Uint8ListTransformer()),
              connection, nullLogger);
        }
      } else {
        _createAdapter(stdin, stdout.nonBlocking, nullLogger);
      }
    },
    (e, s) {
      final errorLogDir = Directory.systemTemp.createTempSync('dart_dap_error');
      final errorLogFile = File(path.join(errorLogDir.path, 'error.txt'));
      errorLogFile.writeAsStringSync('$e\n$s');
      throw e;
    },
  );
}

final parser = ArgParser(usageLineLength: 80)
  ..addOption(
    'port',
    abbr: 'p',
    help: 'Runs the DAP in multi-session mode bound to the supplied port. '
        'Will bind to a random port if 0 is supplied. '
        'The port will be printed in a json message to stdout:\n'
        '{"event": "serverPort", "port": 123}',
  )
  ..addFlag('verbose',
      help:
          'Prints diagnostic message to stdout if running in multi-session mode.'
          'stdout is used for communication so cannot be printed to in single-session mode.')
  ..addFlag('help', help: 'Prints this help text', negatable: false);

void _createAdapter(
    Stream<List<int>> _input, StreamSink<List<int>> _output, Logger logger) {
  // TODO(dantup): Handle picking different debug adapters for Dart/Flutter/Testing.
  final channel = LspByteStreamServerChannel(_input, _output, logger);
  final adapter = DartDebugAdapter(channel, nullLogger);
  // TODO(dantup): Wait for exits?
}
