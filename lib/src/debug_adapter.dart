import 'dart:async';

import 'package:dap/src/debug_adapter_protocol.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

void _voidFromJson(Map<String, Object?> obj) => null;

/// A base for all debug adapters that converts communication over
/// [LspByteStreamServerChannel] into appropriate method calls/events.
abstract class DebugAdapter<TLaunchArgs extends LaunchRequestArguments> {
  int _sequence = 1;
  final LspByteStreamServerChannel _channel;
  final Logger logger;

  DebugAdapter(this._channel, this.logger) {
    _channel.listen(_handleIncomingMessage);
  }

  /// Parses arguments for [launchRequest] into a type of [TLaunchArgs].
  ///
  /// This method must be implemented by the implementing class using a class
  /// that corresponds to the arguments it expects (these may differ between
  /// Dart CLI, Dart tests, Flutter, Flutter tests).
  TLaunchArgs Function(Map<String, Object?>) get parseLaunchArgs;

  FutureOr<void> configurationDoneRequest(Request request,
      ConfigurationDoneArguments? args, void Function(void) sendResponse);

  FutureOr<void> continueRequest(Request request, ContinueArguments args,
      void Function(void) sendResponse);

  FutureOr<void> disconnectRequest(Request request, DisconnectArguments? args,
      void Function(void) sendResponse);

  FutureOr<void> evaluateRequest(Request request, EvaluateArguments args,
      void Function(EvaluateResponseBody) sendResponse);

  /// Calls [handler] for an incoming request, using [fromJson] to parse its
  /// arguments from the request.
  ///
  /// [handler] will provided a function [sendResponse] that it can use to
  /// sends its response without needing to build a [Response] from fields on
  /// the request.
  ///
  /// [handler] must _always_ call [sendResponse], even if the response does not
  /// require a body.
  FutureOr<void> handle<TArg, TResp>(
    Request request,
    FutureOr<void> Function(Request, TArg, void Function(TResp)) handler,
    TArg Function(Map<String, Object?>) fromJson,
  ) async {
    final args = request.arguments != null
        ? fromJson(request.arguments as Map<String, Object?>)
        // arguments are only valid to be null then TArg is nullable.
        : null as TArg;

    // Because handlers may need to send responses before they have finished
    // executing (for example, initializeRequest needs to send its response
    // before sending InitializedEvent()), we pass in a function `sendResponse`
    // rather than using a return value.
    var sendResponseCalled = false;
    void sendResponse(TResp responseBody) {
      assert(!sendResponseCalled,
          'sendResponse was called multiple times by ${request.command}');
      sendResponseCalled = true;
      final response = Response(
        success: true,
        requestSeq: request.seq,
        seq: _sequence++,
        command: request.command,
        body: responseBody,
      );
      _channel.sendResponse(response);
    }

    await handler(request, args, sendResponse);
    assert(sendResponseCalled,
        'sendResponse was not called in ${request.command}');
  }

  FutureOr<void> initializeRequest(
      Request request,
      InitializeRequestArguments args,
      void Function(Capabilities) sendResponse);

  FutureOr<void> launchRequest(
      Request request, TLaunchArgs args, void Function(void) sendResponse);

  FutureOr<void> nextRequest(
      Request request, NextArguments args, void Function(void) sendResponse);

  FutureOr<void> scopesRequest(Request request, ScopesArguments args,
      void Function(ScopesResponseBody) sendResponse);

  /// Sends an event, lookup up the event type based on the runtimeType of
  /// [body].
  void sendEvent(EventBody body) {
    final event = Event(
      seq: _sequence++,
      event: eventTypes[body.runtimeType]!,
      body: body,
    );
    _channel.sendEvent(event);
  }

  /// Sends a request to the client, looking up the request type based on the
  /// runtimeType of [arguments].
  void sendRequest(RequestArguments arguments) {
    final request = Request(
      seq: _sequence++,
      command: commandTypes[arguments.runtimeType]!,
      arguments: arguments,
    );
    _channel.sendRequest(request);
  }

  FutureOr<void> setBreakpointsRequest(
      Request request,
      SetBreakpointsArguments args,
      void Function(SetBreakpointsResponseBody) sendResponse);

  FutureOr<void> stackTraceRequest(Request request, StackTraceArguments args,
      void Function(StackTraceResponseBody) sendResponse);

  FutureOr<void> stepInRequest(
      Request request, StepInArguments args, void Function(void) sendResponse);

  FutureOr<void> stepOutRequest(
      Request request, StepOutArguments args, void Function(void) sendResponse);

  FutureOr<void> terminateRequest(Request request, TerminateArguments? args,
      void Function(void) sendResponse);

  FutureOr<void> threadsRequest(Request request, void args,
      void Function(ThreadsResponseBody) sendResponse);

  FutureOr<void> variablesRequest(Request request, VariablesArguments args,
      void Function(VariablesResponseBody) sendResponse);

  /// Handles incoming messages from the client editor.
  void _handleIncomingMessage(ProtocolMessage message) {
    if (message is Request) {
      try {
        _handleIncomingRequest(message);
      } catch (e, s) {
        // TODO(dantup): Review whether this error handling is sufficient.
        final response = Response(
          success: false,
          requestSeq: message.seq,
          seq: _sequence++,
          command: message.command,
          message: '$e',
          body: '$s',
        );
        _channel.sendResponse(response);
      }
    } else if (message is Response) {
      // TODO(dantup): Determine how to handle errors in responses from clients.
      _handleIncomingResponse(message);
    } else {
      // TODO(dantup): Determine how to handle this.
      throw Exception('Unknown Protocol message ${message.type}');
    }
  }

  /// Handles an incoming request, calling the appropriate method to handle it.
  void _handleIncomingRequest(Request request) {
    if (request.command == 'initialize') {
      handle(request, initializeRequest, InitializeRequestArguments.fromJson);
    } else if (request.command == 'launch') {
      handle(request, launchRequest, parseLaunchArgs);
    } else if (request.command == 'terminate') {
      handle(request, terminateRequest, TerminateArguments.fromJson);
    } else if (request.command == 'disconnect') {
      handle(request, disconnectRequest, DisconnectArguments.fromJson);
    } else if (request.command == 'configurationDone') {
      handle(request, configurationDoneRequest,
          ConfigurationDoneArguments.fromJson);
    } else if (request.command == 'setBreakpoints') {
      handle(request, setBreakpointsRequest, SetBreakpointsArguments.fromJson);
    } else if (request.command == 'stackTrace') {
      handle(request, stackTraceRequest, StackTraceArguments.fromJson);
    } else if (request.command == 'threads') {
      handle(request, threadsRequest, _voidFromJson);
    } else if (request.command == 'scopes') {
      handle(request, scopesRequest, ScopesArguments.fromJson);
    } else if (request.command == 'continue') {
      handle(request, continueRequest, ContinueArguments.fromJson);
    } else if (request.command == 'next') {
      handle(request, nextRequest, NextArguments.fromJson);
    } else if (request.command == 'stepIn') {
      handle(request, stepInRequest, StepInArguments.fromJson);
    } else if (request.command == 'stepOut') {
      handle(request, stepOutRequest, StepOutArguments.fromJson);
    } else if (request.command == 'variables') {
      handle(request, variablesRequest, VariablesArguments.fromJson);
    } else if (request.command == 'evaluate') {
      handle(request, evaluateRequest, EvaluateArguments.fromJson);
    } else {
      throw Exception('Unknown command: ${request.command}');
    }
  }

  void _handleIncomingResponse(Response response) {
    // TODO(dantup): Implement this (required for runInTerminalRequest).
  }
}
