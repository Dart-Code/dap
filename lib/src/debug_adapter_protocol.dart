import 'package:dap/src/debug_protocol.dart';
import 'package:meta/meta.dart';

// TODO(dantup): This file should be generated from the DAP spec.

void handleRequest(DebugAdapterProtocol dap, Request request) {
  dap._handleRequest(request);
}

abstract class DebugAdapterProtocol {
  Future<void> disconnectRequest(
      DisconnectArgs args, Request request, void Function(void) sendResponse);
  Future<void> initializeRequest(InitializeArgs args, Request request,
      void Function(Capabilities) sendResponse);
  Future<void> launchRequest(
      LaunchArgs args, Request request, void Function(void) sendResponse);
  Future<void> configurationDoneRequest(ConfigurationDoneArgs args,
      Request request, void Function(void) sendResponse);

  @visibleForOverriding
  Future<void> handle<TArg, TResp>(
    Request request,
    Future<void> Function(TArg, Request, void Function(TResp)) handler,
    TArg Function(Map<String, Object?>) fromJson,
  );

  void _handleRequest(Request request) {
    if (request.command == 'initialize') {
      handle(request, initializeRequest, InitializeArgs.fromJson);
    } else if (request.command == 'launch') {
      handle(request, launchRequest, LaunchArgs.fromJson);
    } else if (request.command == 'disconnect') {
      handle(request, disconnectRequest, DisconnectArgs.fromJson);
    } else if (request.command == 'configurationDone') {
      handle(request, configurationDoneRequest, ConfigurationDoneArgs.fromJson);
    } else {
      throw Exception('Unknown command: ${request.command}');
    }
  }
}
