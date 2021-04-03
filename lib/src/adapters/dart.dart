import 'dart:async';

import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/debug_protocol.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';

class DartDebugAdapter extends BaseDebugAdapter {
  DartDebugAdapter(LspByteStreamServerChannel channel) : super(channel);

  @override
  Future<void> disconnectRequest(DisconnectArgs args, Request request,
      void Function(void) respondWith) async {
    // TODO(dantup): implement disconnectRequest
    throw UnimplementedError();
  }

  @override
  Future<void> initializeRequest(InitializeArgs args, Request request,
      void Function(Capabilities) respondWith) async {
    respondWith(Capabilities(supportsConfigurationDoneRequest: true));

    // This must only be sent AFTER the response.
    sendEvent(InitializedEventBody()); // ???
  }

  @override
  Future<void> launchRequest(
      LaunchArgs args, Request request, void Function(void) respondWith) async {
    // TODO(dantup): implement launchRequest
    throw UnimplementedError();
  }
}
