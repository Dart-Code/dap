import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/debug_protocol.dart';

class DartDebugAdapter extends DebugAdapter {
  @override
  Future<Null> disconnectRequest(DisconnectArgs args, Request request) async {
    // TODO: implement disconnectRequest
    throw UnimplementedError();
  }

  @override
  Future<Capabilities> initializeRequest(
      InitializeArgs args, Request request) async {
    return Capabilities(supportsConfigurationDoneRequest: false);
  }

  @override
  Future<Null> launchRequest(LaunchArgs args, Request request) async {
    // TODO: implement launchRequest
    throw UnimplementedError();
  }
}
