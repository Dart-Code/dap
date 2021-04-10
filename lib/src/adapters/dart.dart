import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:dap/src/debug_adapter_common.dart';
import 'package:dap/src/debug_adapter_protocol.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:pedantic/pedantic.dart';

class DartDebugAdapter extends CommonDebugAdapter {
  Process? _process;

  DartDebugAdapter(LspByteStreamServerChannel channel) : super(channel);

  @override
  Future<void> configurationDoneRequest(ConfigurationDoneArgs args,
      Request request, void Function(void) sendResponse) async {
    sendResponse(null); // TODO(dantup): Why is this null needed?
  }

  @override
  Future<void> disconnectRequest(DisconnectArgs args, Request request,
      void Function(void) sendResponse) async {
    // TODO(dantup): implement disconnectRequest
    throw UnimplementedError();
  }

  @override
  Future<void> initializeRequest(InitializeArgs args, Request request,
      void Function(Capabilities) sendResponse) async {
    sendResponse(Capabilities(supportsConfigurationDoneRequest: true));

    // This must only be sent AFTER the response.
    sendEvent(InitializedEventBody()); // ???
  }

  @override
  Future<void> launchRequest(
    LaunchArgs args,
    Request request,
    void Function(void) sendResponse,
  ) async {
    final dartVmPath = path.join(args.dartSdkPath, 'bin/dart');
    final process = await Process.start(
        dartVmPath, [args.program, ...?args.args],
        workingDirectory: args.cwd);
    _process = process;
    process.stdout.listen(_handleStdout);
    process.stderr.listen(_handleStderr);
    unawaited(process.exitCode.then(_handleExitCode));

    sendResponse(null);
  }

  void _handleExitCode(int code) {
    final codeSuffix = code == 0 ? '' : ' ($code)';
    sendEvent(
      // Always add a newline since the last printed text might not have had
      // one.
      OutputEventBody(category: 'console', output: '\nExited$codeSuffix.'),
    );
    sendEvent(TerminatedEventBody());
  }

  void _handleStdout(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stdout', output: utf8.decode(data)));
  }

  void _handleStderr(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stderr', output: utf8.decode(data)));
  }
}
