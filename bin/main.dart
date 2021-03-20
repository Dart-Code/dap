import 'dart:io';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_session.dart';

void main(List<String> args) {
  // TODO: Handle picking different debug adapters for Dart/Flutter/Testing.
  final adapter = DartDebugAdapter();
  DebugSession.start(stdin, stdout.nonBlocking, adapter);
}
