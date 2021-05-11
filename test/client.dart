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
  final Map<int, _OutgoingRequest> _pendingRequests = {};
  final _eventController = StreamController<Event>.broadcast();
  int _seq = 1;
  final _requestWarningDuration = const Duration(seconds: 2);

  DapTestClient(this._client) {
    _client.listen((message) {
      if (message is Response) {
        final pendingRequest = _pendingRequests.remove(message.requestSeq);
        if (pendingRequest == null) {
          return;
        }
        final completer = pendingRequest.completer;
        if (message.success || pendingRequest.allowFailure) {
          completer.complete(message);
        } else {
          completer.completeError(message);
        }
      } else if (message is Event) {
        _eventController.add(message);

        // When we see a terminated event, close the event stream so if any
        // tests are waiting on something that will never come, they fail at
        // a useful location.
        if (message.event == 'terminated') {
          _eventController.close();
        }
      }
    }, onDone: () {
      _pendingRequests.forEach((id, request) => request.completer.completeError(
          'Application terminated without a response to request $id (${request.name})'));
      _pendingRequests.clear();
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

  Future<Response> evaluate(String expression,
          {int? frameId, String? context}) =>
      sendRequest(EvaluateArguments(
          expression: expression, frameId: frameId, context: context));

  /// Returns a Future that completes with the next [event] event.
  Future<Event> event(String event) => _logIfSlow('Event "$event"',
      _eventController.stream.firstWhere((e) => e.event == event));

  /// Returns a stream for [event] events.
  Stream<Event> events(String event) =>
      _eventController.stream.where((e) => e.event == event);

  Future<Response> initialize({String exceptionPauseMode = 'None'}) async {
    final responses = await Future.wait([
      event('initialized'),
      sendRequest(InitializeRequestArguments(adapterID: 'test')),
      sendRequest(
          SetExceptionBreakpointsArguments(filters: [exceptionPauseMode])),
    ]);
    await sendRequest(ConfigurationDoneArguments());
    return responses[1] as Response; // Return the initialize response.
  }

  Future<Response> launch(String program,
      {List<String>? args,
      FutureOr<String>? cwd,
      bool? noDebug,
      bool? evaluateGettersInDebugViews}) async {
    return sendRequest(
      DartLaunchRequestArguments(
        noDebug: noDebug,
        program: program,
        cwd: await (cwd ?? testApplicationsDirectory),
        args: args,
        dartSdkPath: path.dirname(path.dirname(Platform.resolvedExecutable)),
        evaluateGettersInDebugViews: evaluateGettersInDebugViews,
      ),
      // We can't automatically pick the command when using a custom type
      // (DartLaunchRequestArguments).
      overrideCommand: 'launch',
    );
  }

  Future<Response> next(int threadId) =>
      sendRequest(NextArguments(threadId: threadId));

  Future<Response> scopes(int frameId) =>
      sendRequest(ScopesArguments(frameId: frameId));

  Future<Response> sendRequest(Object? arguments,
      {bool allowFailure = false, String? overrideCommand}) {
    final command = overrideCommand ?? commandTypes[arguments.runtimeType]!;
    final request =
        Request(seq: _seq++, command: command, arguments: arguments);
    final completer = Completer<Response>();
    _pendingRequests[request.seq] =
        _OutgoingRequest(completer, command, allowFailure);
    _client.sendRequest(request);
    return _logIfSlow('Request "$command"', completer.future);
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

  Future<Response> variables(int variablesReference,
          {int? start, int? count}) =>
      sendRequest(VariablesArguments(
          variablesReference: variablesReference, start: start, count: count));

  /// Prints a warning if [future] takes longer than [_requestWarningDuration]
  /// to complete.
  ///
  /// Returns [future].
  Future<T> _logIfSlow<T>(String name, Future<T> future) {
    var didComplete = false;
    future.then((_) => didComplete = true);
    Future.delayed(_requestWarningDuration).then((_) {
      if (!didComplete) {
        print(
            '$name has taken longer than ${_requestWarningDuration.inSeconds}s');
      }
    });
    return future;
  }
}

class _OutgoingRequest {
  final Completer<Response> completer;
  final String name;
  final bool allowFailure;

  _OutgoingRequest(this.completer, this.name, this.allowFailure);
}
