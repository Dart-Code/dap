import 'dart:async';

import 'package:dap/src/debug_adapter_protocol.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

/// A helper class to simplify interacting with the DapTestServer.
class DapTestClient {
  final LspByteStreamServerChannel _client;
  final Map<int, Completer<Response>> _requestCompleters = {};
  final _eventController = StreamController<Event>.broadcast();
  int _seq = 1;

  DapTestClient(this._client) {
    _client.listen((message) {
      if (message is Response) {
        final completer = _requestCompleters.remove(message.requestSequence);
        completer?.complete(message);
      } else if (message is Event) {
        _eventController.add(message);

        // Handle termination.
        if (message.event == 'terminated') {
          _eventController.close();
          _requestCompleters.forEach((id, completer) => completer.completeError(
              'Application terminated without a response to request $id'));
        }
      }
    });
  }

  /// Returns a Future that completes with the next [event] event.
  Future<Event> event(String event) =>
      _eventController.stream.firstWhere((e) => e.event == event);

  /// Returns a stream for [event] events.
  Stream<Event> events(String event) =>
      _eventController.stream.where((e) => e.event == event);

  Future<Response> sendRequest(String command, Object? arguments) {
    final request = Request(_seq++, command, arguments);
    final completer = Completer<Response>();
    _requestCompleters[request.sequence] = completer;
    _client.sendRequest(request);
    return completer.future;
  }
}
