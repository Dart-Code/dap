import 'package:dap/src/debug_adapter_protocol.dart';
import 'package:dap/src/debug_protocol.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

abstract class BaseDebugAdapter extends DebugAdapterProtocol {
  int _sequence = 1;
  final LspByteStreamServerChannel _channel;

  BaseDebugAdapter(this._channel) {
    _channel.listen((ProtocolMessage message) {
      if (message is Request) {
        try {
          handleRequest(this, message);
        } catch (e, s) {
          // TODO(dantup): Review whether this error handling is sufficient.
          final response = Response.failure(
              _sequence++, message.sequence, message.command, '$e', '$s');
          _channel.sendResponse(response);
        }
      } else if (message is Response) {
        // TODO(dantup): Determine how to handle errors in responses from clients.
        _handleResponse(message);
      } else {
        // TODO(dantup): Determine how to handle this.
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
    final args = fromJson(request.arguments as Map<String, Object?>);

    // Handlers may need to send responses before they have finished executing
    // (or example, initializeRequest needs to send its response before then
    // sending InitializedEvent()). To avoid having to create new futures to
    // delay sending the events, pass in a handler that can send the response
    // that ensures sendResponse is called exactly once in the handler.
    var sendResponseCalled = false;
    void sendResponse(TResp responseBody) {
      assert(!sendResponseCalled,
          'sendResponse was called multiple times in ${request.command}');
      sendResponseCalled = true;
      final response = Response.success(
          _sequence++, request.sequence, request.command, responseBody);
      _channel.sendResponse(response);
    }

    await handler(args, request, sendResponse);
    assert(sendResponseCalled,
        'sendResponse was not called in ${request.command}');
  }

  void _handleResponse(Response response) {}
}
