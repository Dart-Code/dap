import 'dart:io';

import 'package:vm_service/vm_service.dart' as vm;

// TODO(dantup): See if there's a standard logger package or something we can use.

final nullLogger = _NullLogger();

class FileLogger extends Logger {
  final IOSink _sink;

  FileLogger(File _file) : _sink = _file.openWrite(mode: FileMode.write);

  @override
  void log(String message) => _sink.writeln(message);
}

abstract class Logger {
  void log(String message);
}

class MultiLogger extends Logger {
  final Set<Logger> loggers = {};

  MultiLogger();

  @override
  void log(String message) => loggers.forEach((logger) => logger.log(message));
}

class VmLogger extends vm.Log {
  final Logger _logger;

  VmLogger(this._logger);

  @override
  void severe(String message) => _logger.log('ERROR: $message');

  @override
  void warning(String message) => _logger.log('WARN: $message');
}

class _NullLogger extends Logger {
  @override
  void log(String message) {}
}
