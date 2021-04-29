import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:meta/meta.dart';

// TODO(dantup): Should this file be generated from the DAP spec?

void handleRequest(DebugAdapter dap, Request request) {
  dap._handleRequest(request);
}

abstract class DebugAdapter<TLaunchArgs extends LaunchRequestArguments> {
  Future<void> configurationDoneRequest(ConfigurationDoneArguments? args,
      Request request, void Function(void) sendResponse);

  Future<void> disconnectRequest(DisconnectArguments? args, Request request,
      void Function(void) sendResponse);

  @visibleForOverriding
  Future<void> handle<TArg, TResp>(
    Request request,
    Future<void> Function(TArg?, Request, void Function(TResp)) handler,
    TArg Function(Map<String, Object?>) fromJson,
  );

  Future<void> initializeRequest(InitializeRequestArguments? args,
      Request request, void Function(Capabilities) sendResponse);

  Future<void> launchRequest(
      TLaunchArgs? args, Request request, void Function(void) sendResponse);

  TLaunchArgs Function(Map<String, Object?>) get parseLaunchArgs;

  void _handleRequest(Request request) {
    if (request.command == 'initialize') {
      handle(request, initializeRequest, InitializeRequestArguments.fromJson);
    } else if (request.command == 'launch') {
      handle(request, launchRequest, parseLaunchArgs);
    } else if (request.command == 'disconnect') {
      handle(request, disconnectRequest, DisconnectArguments.fromJson);
    } else if (request.command == 'configurationDone') {
      handle(request, configurationDoneRequest,
          ConfigurationDoneArguments.fromJson);
    } else {
      throw Exception('Unknown command: ${request.command}');
    }
  }
}
