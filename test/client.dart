import 'dart:async';
import 'dart:io';

import 'package:dap/src/adapters/dart.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;

import 'test_utils.dart';

/// A helper class to simplify interacting with the DapTestServer.
class DapTestClient {
  final LspByteStreamServerChannel _client;
  final Map<int, Completer<Response>> _requestCompleters = {};
  final _eventController = StreamController<Event>.broadcast();
  int _seq = 1;
  final _requestTimeout = const Duration(seconds: 10);

  DapTestClient(this._client) {
    _client.listen((message) {
      if (message is Response) {
        final completer = _requestCompleters.remove(message.requestSeq);
        if (message.success) {
          completer?.complete(message);
        } else {
          completer?.completeError(message);
        }
      } else if (message is Event) {
        _eventController.add(message);

        // Handle termination.
        if (message.event == 'terminated') {
          _eventController.close();
          _requestCompleters.forEach((id, completer) => completer.completeError(
              'Application terminated without a response to request $id'));
          _requestCompleters.clear();
        }
      }
    });
  }

  /// Returns a stream of [OutputEventBody] events.
  Stream<OutputEventBody> get outputEvents => events('output')
      .map((e) => OutputEventBody.fromJson(e.body as Map<String, Object?>));

  /// Returns a stream [StoppedEventBody] events.
  Stream<StoppedEventBody> get stoppedEvents => events('stopped')
      .map((e) => StoppedEventBody.fromJson(e.body as Map<String, Object?>));

  Future<Response> continue_(int threadId) =>
      sendRequest(ContinueArguments(threadId: threadId));

  Future<Response> disconnect() => sendRequest(DisconnectArguments());

  /// Returns a Future that completes with the next [event] event.
  Future<Event> event(String event) =>
      _eventController.stream.firstWhere((e) => e.event == event);

  /// Returns a stream for [event] events.
  Stream<Event> events(String event) =>
      _eventController.stream.where((e) => e.event == event);

  Future<Response> initialize() async {
    final responses = await Future.wait([
      event('initialized'),
      sendRequest(InitializeRequestArguments(adapterID: 'test')),
    ]);
    await sendRequest(ConfigurationDoneArguments());
    return responses[1] as Response; // Return the initialize response.
  }

  Future<void> launch(String program,
      {List<String>? args, FutureOr<String>? cwd, bool? noDebug}) async {
    await sendRequest(
      DartLaunchRequestArguments(
        noDebug: noDebug,
        program: program,
        cwd: await (cwd ?? testApplicationsDirectory),
        args: args,
        dartSdkPath: path.dirname(path.dirname(Platform.resolvedExecutable)),
      ),
      // We can't automatically pick the command when using a custom type
      // (DartLaunchRequestArguments).
      overrideCommand: 'launch',
    );
  }

  Future<Response> next(int threadId) =>
      sendRequest(NextArguments(threadId: threadId));

  Future<Response> sendRequest(Object? arguments,
      {bool allowFailure = false, String? overrideCommand}) {
    final command = overrideCommand ?? commandTypes[arguments.runtimeType]!;
    final request =
        Request(seq: _seq++, command: command, arguments: arguments);
    final completer = Completer<Response>();
    _requestCompleters[request.seq] = completer;
    _client.sendRequest(request);
    return completer.future.timeout(_requestTimeout);
  }

  Future<Response> stackTrace(int threadId,
          {int? startFrame, int? numFrames}) =>
      sendRequest(StackTraceArguments(
          threadId: threadId, startFrame: startFrame, levels: numFrames));

  Future<Response> stepIn(int threadId) =>
      sendRequest(StepInArguments(threadId: threadId));

  Future<Response> stepOut(int threadId) =>
      sendRequest(StepOutArguments(threadId: threadId));

  Future<Response> terminate() => sendRequest(TerminateArguments());
}
