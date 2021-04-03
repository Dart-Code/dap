import 'dart:io';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

void main(List<String> args) {
  // TODO(dantup): Handle picking different debug adapters for Dart/Flutter/Testing.
  final channel = LspByteStreamServerChannel(stdin, stdout.nonBlocking);
  final adapter = DartDebugAdapter(channel);
  // TODO(dantup): Wait for exit?
}
