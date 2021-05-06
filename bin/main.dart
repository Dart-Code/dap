import 'dart:async';
import 'dart:io';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;

void main(List<String> args) {
  runZonedGuarded(
    () async {
      // Isolate.current.setErrorsFatal(false);
      // TODO(dantup): Handle picking different debug adapters for Dart/Flutter/Testing.
      final channel =
          LspByteStreamServerChannel(stdin, stdout.nonBlocking, nullLogger);
      final adapter = DartDebugAdapter(channel, nullLogger);
      // TODO(dantup): Wait for exit?
    },
    (e, s) {
      final errorLogDir = Directory.systemTemp.createTempSync('dart_dap_error');
      final errorLogFile = File(path.join(errorLogDir.path, 'error.txt'));
      errorLogFile.writeAsStringSync('$e\n$s');
      throw e;
    },
  );
}
