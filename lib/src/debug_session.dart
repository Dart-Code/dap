import 'dart:async';

import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/debug_protocol.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

class DebugSession {
  final LspByteStreamServerChannel _channel;
  final DebugAdapter _adapter;
  int _sequence = 1;

  /// Starts a DAP debug session using [adapter] communicating over [input]
  /// and [output].
  static DebugSession start(
    Stream<List<int>> input,
    StreamSink<List<int>> output,
    DebugAdapter adapter,
  ) {
    return DebugSession._(LspByteStreamServerChannel(input, output), adapter);
  }

  DebugSession._(this._channel, this._adapter) {
    _channel.listen((ProtocolMessage message) {
      if (message is Request) {
        _handleRequest(message);
      } else if (message is Event) {
        _handleEvent(message);
      } else if (message is Response) {
        _handleResponse(message);
      }
    });
  }

  void _handleRequest(Request request) {
    // TODO: This should be generated from the DAP spec.
    if (request.command == 'initialize') {
      _handle(request, _adapter.initializeRequest, InitializeArgs.fromJson);
    } else if (request.command == 'launch') {
      _handle(request, _adapter.launchRequest, LaunchArgs.fromJson);
    } else if (request.command == 'disconnect') {
      _handle(request, _adapter.disconnectRequest, DisconnectArgs.fromJson);
    }
  }

  void _handleEvent(Event event) {}
  void _handleResponse(Response response) {}

  Future<void> _handle<TArg>(
    Request request,
    Future<Object?> Function(TArg, Request) handler,
    TArg Function(Map<String, Object?>) fromJson,
  ) async {
    try {
      final args = fromJson(request.arguments as Map<String, Object?>);
      final responseBody = await handler(args, request);
      final response = Response.success(
          _sequence++, request.sequence, request.command, responseBody);
      _channel.sendResponse(response);
    } catch (e, s) {
      // TODO: Review whether this error handling is sufficient.
      final response = Response.failure(
          _sequence++, request.sequence, request.command, '$e', '$s');
      _channel.sendResponse(response);
    }
  }
}
