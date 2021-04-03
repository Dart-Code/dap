import 'package:dap/src/debug_adapter_protocol.dart';
import 'package:dap/src/debug_protocol.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

abstract class BaseDebugAdapter extends DebugAdapterProtocol {
  int _sequence = 1;
  final LspByteStreamServerChannel _channel;

  BaseDebugAdapter(this._channel) {
    _channel.listen((ProtocolMessage message) {
      if (message is Request) {
        handleRequest(this, message);
      } else if (message is Response) {
        _handleResponse(message);
      } else {
        throw Exception('Unknown Protocol message ${message.type}');
      }
    });
  }

  void sendEvent(EventBody event) =>
      _channel.sendEvent(Event(_sequence++, event.event, event));
  void sendRequest(Request request) => _channel.sendRequest(request);

  @override
  Future<void> handle<TArg, TResp>(
    Request request,
    Future<void> Function(TArg, Request, void Function(TResp)) handler,
    TArg Function(Map<String, Object?>) fromJson,
  ) async {
    try {
      final args = fromJson(request.arguments as Map<String, Object?>);

      // Handlers may need to send responses before they have finished executing
      // (or example, initializeRequest needs to send its response before then
      // sending InitializedEvent()). To avoid having to create new futures to
      // delay sending the events, pass in a handler that can send the response
      // that ensures respondWith is called exactly once in the handler.
      var respondWithCalled = false;
      void respondWith(TResp responseBody) {
        assert(!respondWithCalled,
            'respondWith was called multiple times in ${request.command}');
        respondWithCalled = true;
        final response = Response.success(
            _sequence++, request.sequence, request.command, responseBody);
        _channel.sendResponse(response);
      }

      await handler(args, request, respondWith);
      assert(respondWithCalled,
          'respondWith was not called in ${request.command}');
    } catch (e, s) {
      // TODO(dantup): Review whether this error handling is sufficient.
      final response = Response.failure(
          _sequence++, request.sequence, request.command, '$e', '$s');
      _channel.sendResponse(response);
    }
  }

  void _handleResponse(Response response) {}
}
