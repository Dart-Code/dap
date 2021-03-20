import 'package:dap/src/debug_protocol.dart';

abstract class DebugAdapter {
  Future<Capabilities> initializeRequest(InitializeArgs args, Request request);
  Future<Null> disconnectRequest(DisconnectArgs args, Request request);
  Future<Null> launchRequest(LaunchArgs args, Request request);
}
