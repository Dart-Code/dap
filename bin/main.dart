import 'dart:io';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_session.dart';

void main(List<String> args) {
  final adapter = DartDebugAdapter();
  DebugSession.run(stdin, stdout.nonBlocking, adapter);
}
