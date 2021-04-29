import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dap/src/debug_adapter_common.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';

class DartDebugAdapter extends CommonDebugAdapter<DartLaunchRequestArguments> {
  Process? _process;

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;

  DartDebugAdapter(LspByteStreamServerChannel channel) : super(channel);

  @override
  Future<void> configurationDoneRequest(ConfigurationDoneArguments? args,
      Request request, void Function(void) sendResponse) async {
    sendResponse(null); // TODO(dantup): Why is this null needed?
  }

  @override
  Future<void> disconnectRequest(DisconnectArguments? args, Request request,
      void Function(void) sendResponse) async {
    // TODO(dantup): implement disconnectRequest
    throw UnimplementedError();
  }

  @override
  Future<void> initializeRequest(InitializeRequestArguments? args,
      Request request, void Function(Capabilities) sendResponse) async {
    sendResponse(Capabilities(supportsConfigurationDoneRequest: true));

    // This must only be sent AFTER the response.
    sendEvent(InitializedEventBody()); // ???
  }

  @override
  Future<void> launchRequest(
    DartLaunchRequestArguments? args,
    Request request,
    void Function(void) sendResponse,
  ) async {
    if (args == null) {
      throw Exception('launchRequest requires non-null arguments');
    }
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

  void _handleStderr(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stderr', output: utf8.decode(data)));
  }

  void _handleStdout(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stdout', output: utf8.decode(data)));
  }
}

class DartLaunchRequestArguments extends LaunchRequestArguments {
  final String dartSdkPath;
  final String program;
  final List<String>? args;
  final String? cwd;

  DartLaunchRequestArguments({
    Object? restart,
    bool? noDebug,
    required this.dartSdkPath,
    required this.program,
    this.args,
    this.cwd,
  }) : super(restart: restart, noDebug: noDebug);

  DartLaunchRequestArguments.fromMap(Map<String, Object?> obj)
      : dartSdkPath = obj['dartSdkPath'] as String,
        program = obj['program'] as String,
        args = (obj['args'] as List?)?.cast<String>(),
        cwd = obj['cwd'] as String?,
        super.fromMap(obj);

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        'dartSdkPath': dartSdkPath,
        'program': program,
        'args': args,
        'cwd': cwd,
      };

  static DartLaunchRequestArguments fromJson(Map<String, Object?> obj) =>
      DartLaunchRequestArguments.fromMap(obj);
}
