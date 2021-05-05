import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart' hide Event;
import 'package:dap/src/logging.dart';
import 'package:dap/src/mapping.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';
import 'package:vm_service/vm_service.dart' as vm;

class DartDebugAdapter extends DebugAdapter<DartLaunchRequestArguments> {
  late IsolateManager _isolateManager;
  Process? _process;
  var _debug = false;
  File? _vmServiceInfoFile;
  StreamSubscription<FileSystemEvent>? _vmServiceInfoFileWatcher;
  final _tmpDir = Directory.systemTemp;
  vm.VmServiceInterface? _vmService;
  // We normally track the pid from the VM service to terminate the VM
  // afterwards (since [_process] may be a shell), but for `flutter run` it's
  // a remote PID and therefore doesn't make sense to try and terminate.
  var _allowTerminatingVmServicePid = true;
  final _pidsToTerminate = <int>{};
  final _configurationDoneCompleter = Completer<void>();

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;

  // TODO(dantup): Ensure this is cleaned up!
  final _subscriptions = <StreamSubscription<vm.Event>>[];

  DartDebugAdapter(LspByteStreamServerChannel channel, Logger logger)
      : super(channel, logger) {
    _isolateManager = IsolateManager(this);
  }

  FutureOr<void> attachRequest(
    Request request,
    AttachRequestArguments? args,
    void Function(void) sendResponse,
  ) async {
    // Reminder: Don't start launching until configurationDone.
    await _configurationDoneCompleter.future;
    throw UnimplementedError();
  }

  @override
  FutureOr<void> configurationDoneRequest(
      Request request,
      ConfigurationDoneArguments? args,
      void Function(void) sendResponse) async {
    _configurationDoneCompleter.complete();
    sendResponse(null);
  }

  @override
  FutureOr<void> continueRequest(Request request, ContinueArguments? args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args!.threadId);
    sendResponse(null);
  }

  @override
  FutureOr<void> disconnectRequest(Request request, DisconnectArguments? args,
      void Function(void) sendResponse) async {
    // Disconnect is a forceful kill. Clients should first call terminateRequest
    // which will try to gracefully terminate first.
    // TODO(dantup): In Dart-Code DAP, we try again with SIGINT and wait for
    // 2s before killing.
    _process?.kill(ProcessSignal.sigkill);
    sendResponse(null);
  }

  @override
  FutureOr<void> initializeRequest(
      Request request,
      InitializeRequestArguments? args,
      void Function(Capabilities) sendResponse) async {
    sendResponse(Capabilities(
      // TODO(dantup): All of these...
      // exceptionBreakpointFilters: [
      //   ExceptionBreakpointsFilter(
      //       filter: 'All', label: 'All Exceptions', defaultValue: false),
      //   ExceptionBreakpointsFilter(
      //       filter: 'Unhandled',
      //       label: 'Uncaught Exceptions',
      //       defaultValue: true),
      // ],
      // supportsClipboardContext: true,
      // supportsConditionalBreakpoints: true,
      supportsConfigurationDoneRequest: true,
      supportsDelayedStackTraceLoading: true,
      // supportsEvaluateForHovers: true,
      // supportsLogPoints: true,
      // supportsRestartFrame: true,
      supportsTerminateRequest: true,
    ));

    // This must only be sent AFTER the response!
    sendEvent(InitializedEventBody());
  }

  @override
  FutureOr<void> launchRequest(
    Request request,
    DartLaunchRequestArguments? args,
    void Function(void) sendResponse,
  ) async {
    if (args == null) {
      throw Exception('launchRequest requires non-null arguments');
    }
    _debug = args.noDebug != true;

    if (_debug) {
      // TODO(dantup): For some DAs (test, Flutter) we can't use
      // write-service-info so this class will likely need splitting into two
      // (a base DA and a Dart DA).
      final serviceInfoFilePath = args.vmServiceInfoFile ??
          path.join(_tmpDir.createTempSync('dart-vm-service').path, 'vm.json');
      _vmServiceInfoFile = File(serviceInfoFilePath);
    }
    final vmServiceInfoFile = _vmServiceInfoFile;

    final vmPath = path.join(args.dartSdkPath, 'bin/dart');
    final vmArgs = [
      if (_debug) ...[
        '--enable-vm-service=${args.vmServicePort ?? 0}',
        '--pause_isolates_on_start=true',
      ],
      if (_debug && vmServiceInfoFile != null) ...[
        '-DSILENT_OBSERVATORY=true',
        '--write-service-info=${Uri.file(vmServiceInfoFile.path)}'
      ],
      if (args.enableAsserts != false) '--enable-asserts',
      ...?args.vmAdditionalArgs,
    ];

    _vmServiceInfoFileWatcher = vmServiceInfoFile
        ?.watch(events: FileSystemEvent.all)
        .listen(_handleVmServiceInfoEvent);

    // Don't start launching until configurationDone.
    if (!_configurationDoneCompleter.isCompleted) {
      logger.log('Waiting for configurationDone request...');
      await _configurationDoneCompleter.future;
    }

    final processArgs = [
      ...vmArgs,
      args.program,
      ...?args.args,
    ];
    logger.log('Spawning $vmPath with $processArgs in ${args.cwd}');
    final process = await Process.start(
      vmPath,
      processArgs,
      workingDirectory: args.cwd,
    );
    _process = process;

    process.stdout.listen(_handleStdout);
    process.stderr.listen(_handleStderr);
    unawaited(process.exitCode.then(_handleExitCode));

    sendResponse(null);
  }

  @override
  FutureOr<void> nextRequest(Request request, NextArguments? args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args!.threadId, vm.StepOption.kOver);
    sendResponse(null);
  }

  @override
  FutureOr<void> setBreakpointsRequest(
      Request request,
      SetBreakpointsArguments? args,
      void Function(SetBreakpointsResponseBody) sendResponse) async {
    final path = args?.source.path;
    final name = args?.source.name;
    final uri = path != null ? Uri.file(path).toString() : name!;
    final breakpoints = args?.breakpoints ?? [];

    await _isolateManager.setBreakpoints(uri, breakpoints);

    // TODO(dantup): Handle breakpoint resolution rather than pretending all
    // breakpoints are verified immediately.
    sendResponse(SetBreakpointsResponseBody(
      breakpoints: breakpoints.map((e) => Breakpoint(verified: true)).toList(),
    ));
  }

  @override
  FutureOr<void> stackTraceRequest(Request request, StackTraceArguments? args,
      void Function(StackTraceResponseBody) sendResponse) async {
    // How many "extra" frames we claim to have so that the client will
    // let the user fetch them in batches rather than all at once.
    const stackFrameBatchSize = 20;
    final threadId = args?.threadId;
    final thread = _isolateManager._threadsByThreadId[threadId];
    final topFrame = thread?.pauseEvent?.topFrame;
    final startFrame = args?.startFrame ?? 0;
    final numFrames = args?.levels ?? 0;
    var totalFrames = 1;

    if (threadId == null || thread == null) {
      throw 'No thread with threadId $threadId';
    }

    if (!thread.paused) {
      throw 'Thread $threadId is not paused';
    }

    final stackFrames = <StackFrame>[];
    // If the request is only for the top frame, we can satisfy it from the
    // threads `pauseEvent.topFrame`.
    if (startFrame == 0 && numFrames == 1 && topFrame != null) {
      stackFrames
          .add(await convertStackFrame(thread, topFrame, isTopFrame: true));
      totalFrames = 1 + stackFrameBatchSize;
    } else {
      // TODO(dantup): Support more than top frame!
      throw 'TODO';
      // totalFrames = isTruncated ? framesRecieved + stackFrameBatch : framesRecieved
    }

    sendResponse(StackTraceResponseBody(
        stackFrames: stackFrames, totalFrames: totalFrames));
  }

  @override
  FutureOr<void> stepInRequest(Request request, StepInArguments? args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args!.threadId, vm.StepOption.kInto);
    sendResponse(null);
  }

  @override
  FutureOr<void> stepOutRequest(Request request, StepOutArguments? args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args!.threadId, vm.StepOption.kOut);
    sendResponse(null);
  }

  @override
  FutureOr<void> terminateRequest(Request request, TerminateArguments? args,
      void Function(void) sendResponse) async {
    // Terminate is a graceful request to terminate.
    // TODO(dantup): Process additionalPidsToTerminate.
    // TODO(dantup): Remove pause-on-exceptions, breakpoints and resume all threads?
    _process?.kill(ProcessSignal.sigint);
    await _process?.exitCode;
    sendResponse(null);
  }

  @override
  FutureOr<void> threadsRequest(Request request, void args,
      void Function(ThreadsResponseBody) sendResponse) {
    // TODO(dantup): !
    sendResponse(ThreadsResponseBody(threads: []));
  }

  Future<void> _connectDebugger(Uri uri) async {
    uri = _normaliseVmServiceUri(uri);
    logger.log('Connecting to debugger at $uri');
    sendEvent(
      OutputEventBody(
          category: 'console', output: 'Connecting to VM Service at $uri$eol'),
    );
    // TODO(dantup): Support logging of VM traffic.
    final vmService = await _vmServiceConnectUri(
      uri.toString(),
      log: VmLogger(logger),
    );
    logger.log('Connected to debugger at $uri!');
    // TODO(dantup): VS Code currently depends on a custom dart.debuggerUris
    // event to notify it of VM Services that become available. If this is still
    // required, it will need implementing here.
    _vmService = vmService;

    _subscriptions.addAll([
      vmService.onIsolateEvent.listen(_handleIsolateEvent),
      vmService.onExtensionEvent.listen(_handleExtensionEvent),
      vmService.onDebugEvent.listen(_handleDebugEvent),
      vmService.onServiceEvent.listen(_handleServiceEvent),
      vmService.onLoggingEvent.listen(_handleLoggingEvent),
      vmService.onStdoutEvent.listen(_handleStdoutEvent),
      vmService.onStderrEvent.listen(_handleStderrEvent),
    ]);
    await Future.wait([
      vmService.streamListen(vm.EventStreams.kIsolate),
      vmService.streamListen(vm.EventStreams.kExtension),
      vmService.streamListen(vm.EventStreams.kDebug),
      vmService.streamListen(vm.EventStreams.kService),
      vmService.streamListen(vm.EventStreams.kLogging),
      vmService.streamListen(vm.EventStreams.kStdout),
      vmService.streamListen(vm.EventStreams.kStderr),
    ]);

    final vmInfo = await vmService.getVM();
    logger.log('Connected to ${vmInfo.name} on ${vmInfo.operatingSystem}');

    // If we own this process (we launched it, didn't attach), then we should
    // keep a ref to this process to terminate when we quit. This avoids issues
    // where our process is a shell (eg. flutter shell script) and the kill
    // signal isn't passed on correctly.
    // See: https://github.com/Dart-Code/Dart-Code/issues/907
    if (_allowTerminatingVmServicePid && _process != null) {
      final pid = vmInfo.pid;
      if (pid != null) {
        _pidsToTerminate.add(pid);
      }
    }

    // Process any isolates that may have been created before the streams above
    // were set up.
    final existingIsolateRefs = vmInfo.isolates;
    final existingIsolates = existingIsolateRefs != null
        ? await Future.wait(existingIsolateRefs
            .map((isolateRef) => isolateRef.id)
            .whereNotNull()
            .map(vmService.getIsolate))
        : <vm.Isolate>[];
    await Future.wait(existingIsolates.map((isolate) async {
      // Isolates may have the "None" pauseEvent kind at startup, so infer it
      // from the runnable field.
      final pauseEventKind = isolate.runnable ?? false
          ? vm.EventKind.kIsolateRunnable
          : vm.EventKind.kIsolateStart;
      await _isolateManager.registerIsolate(isolate, pauseEventKind);
      if (isolate.pauseEvent?.kind?.startsWith('Pause') ?? false) {
        await _isolateManager.handleEvent(isolate.pauseEvent!);
      } else if (isolate.runnable == true) {
        await _isolateManager.resumeIsolate(isolate);
      }
    }));
  }

  void _handleDebugEvent(vm.Event event) {
    _isolateManager.handleEvent(event);
  }

  void _handleExitCode(int code) {
    final codeSuffix = code == 0 ? '' : ' ($code)';
    sendEvent(
      // Always add a newline since the last printed text might not have had
      // one.
      OutputEventBody(category: 'console', output: '${eol}Exited$codeSuffix.'),
    );
    sendEvent(TerminatedEventBody());
  }

  void _handleExtensionEvent(vm.Event event) {}

  void _handleIsolateEvent(vm.Event event) {
    _isolateManager.handleEvent(event);
  }

  void _handleLoggingEvent(vm.Event event) {}

  void _handleServiceEvent(vm.Event event) {}

  void _handleStderr(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stderr', output: utf8.decode(data)));
  }

  void _handleStderrEvent(vm.Event event) {}

  void _handleStdout(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stdout', output: utf8.decode(data)));
  }

  void _handleStdoutEvent(vm.Event event) {}

  void _handleVmServiceInfoEvent(FileSystemEvent event) {
    try {
      final content = _vmServiceInfoFile!.readAsStringSync();
      final json = jsonDecode(content);
      final uri = Uri.parse(json['uri']);
      unawaited(_connectDebugger(uri));
      _vmServiceInfoFileWatcher?.cancel();
    } catch (e) {
      // It's possible we tried to read the file before it was completed
      // so just ignore and try again on the next event.
      // TODO(dantup): Log these somewhere to aid debugging?
    }
  }

  Uri _normaliseVmServiceUri(Uri uri) {
    final scheme = uri.scheme.replaceAll('http', 'ws');
    final path = uri.path.endsWith('/ws/') || uri.path.endsWith('/ws')
        ? uri.path
        : uri.path.endsWith('/')
            ? '${uri.path}ws/'
            : '${uri.path}/ws/';

    return uri.replace(
        // Switch http -> ws, https -> wss
        scheme: scheme,
        path: path);
  }

  /// Connect to the given uri and return a new [VmService] instance.
  ///
  /// Copied from package:vm_service to allow logging.
  Future<vm.VmService> _vmServiceConnectUri(String wsUri, {vm.Log? log}) async {
    final socket = await WebSocket.connect(wsUri);
    final controller = StreamController();
    final streamClosedCompleter = Completer();

    socket.listen(
      (data) {
        logger.log('<== [VM] $data');
        controller.add(data);
      },
      onDone: () => streamClosedCompleter.complete(),
    );

    return vm.VmService(
      controller.stream,
      (String message) {
        logger.log('==> [VM] $message');
        socket.add(message);
      },
      log: log,
      disposeHandler: () => socket.close(),
      streamClosed: streamClosedCompleter.future,
    );
  }
}

class DartLaunchRequestArguments extends LaunchRequestArguments {
  final String dartSdkPath;
  final String program;
  final List<String>? args;
  final String? cwd;
  final String? vmServiceInfoFile;
  final int? vmServicePort;
  final List<String>? vmAdditionalArgs;
  final bool? enableAsserts;

  DartLaunchRequestArguments({
    Object? restart,
    bool? noDebug,
    required this.dartSdkPath,
    required this.program,
    this.args,
    this.cwd,
    this.vmServiceInfoFile,
    this.vmServicePort,
    this.vmAdditionalArgs,
    this.enableAsserts,
  }) : super(restart: restart, noDebug: noDebug);

  DartLaunchRequestArguments.fromMap(Map<String, Object?> obj)
      : dartSdkPath = obj['dartSdkPath'] as String,
        program = obj['program'] as String,
        args = (obj['args'] as List?)?.cast<String>(),
        cwd = obj['cwd'] as String?,
        vmServiceInfoFile = obj['vmServiceInfoFile'] as String?,
        vmServicePort = obj['vmServicePort'] as int?,
        vmAdditionalArgs = (obj['vmAdditionalArgs'] as List?)?.cast<String>(),
        enableAsserts = obj['enableAsserts'] as bool?,
        super.fromMap(obj);

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        'dartSdkPath': dartSdkPath,
        'program': program,
        'args': args,
        'cwd': cwd,
        'vmServiceInfoFile': vmServiceInfoFile,
        'vmServicePort': vmServicePort,
        'vmAdditionalArgs': vmAdditionalArgs,
        'enableAsserts': enableAsserts,
      };

  static DartLaunchRequestArguments fromJson(Map<String, Object?> obj) =>
      DartLaunchRequestArguments.fromMap(obj);
}

class IsolateManager {
  final DartDebugAdapter _adapter;
  final Map<String, ThreadInfo> _threadsByIsolateId = {};
  final Map<int, ThreadInfo> _threadsByThreadId = {};
  int _nextThreadNumber = 1;
  final Map<String, List<SourceBreakpoint>> _clientBreakpointsByUri = {};
  final Map<String, Map<String, List<vm.Breakpoint>>>
      _vmBreakpointsByIsolateIdAndUri = {};

  var _nextStoredDataId = 1;

  final _storedData = <int, _StoredData>{};

  IsolateManager(this._adapter);

  Future<T> getObject<T extends vm.Response>(
      vm.IsolateRef isolate, vm.ObjRef object) async {
    final res = await _adapter._vmService?.getObject(isolate.id!, object.id!);
    return res as T;
  }

  /// Handles Isolate and Debug events
  FutureOr<void> handleEvent(vm.Event event) async {
    if (event.isolate?.id == null) {
      // TODO(dantup): Log?
      return;
    }

    final eventKind = event.kind;
    if (eventKind == vm.EventKind.kIsolateStart ||
        eventKind == vm.EventKind.kIsolateRunnable) {
      await registerIsolate(event.isolate!, eventKind!);
    } else if (eventKind == vm.EventKind.kIsolateExit) {
      await _handleExit(event);
    } else if (eventKind?.startsWith('Pause') ?? false) {
      await _handlePause(event);
    } else if (eventKind == vm.EventKind.kResume) {
      await _handleResumed(event);
    }
  }

  FutureOr<void> registerIsolate(
      vm.IsolateRef isolate, String eventKind) async {
    final info = _threadsByIsolateId.putIfAbsent(isolate.id!, () {
      final info = ThreadInfo(this, _nextThreadNumber++, isolate);
      _threadsByThreadId[info.threadId] = info;
      _adapter.sendEvent(
          ThreadEventBody(reason: 'started', threadId: info.threadId));
      return info;
    });

    // If it's just become runnable (IsolateRunnable), then set up breakpoints
    // and exception pause mode.
    if (eventKind == vm.EventKind.kIsolateRunnable && !info.runnable) {
      info.runnable = true;
      await _configureIsolate(isolate);
    }
  }

  FutureOr<void> resumeIsolate(vm.IsolateRef isolateRef,
      [String? resumeType]) async {
    final isolateId = isolateRef.id;
    if (isolateId == null) {
      return;
    }

    final thread = _threadsByIsolateId[isolateId];
    if (thread == null) {
      return;
    }

    await resumeThread(thread.threadId);
  }

  Future<void> resumeThread(int threadId, [String? resumeType]) async {
    final thread = _threadsByThreadId[threadId];
    if (thread == null) {
      throw 'Thread $threadId was not found';
    }

    if (!thread.paused || thread.hasPendingResume) {
      return;
    }

    if (resumeType == vm.StepOption.kOver && thread.atAsyncSuspension) {
      resumeType = vm.StepOption.kOverAsyncSuspension;
    }

    thread.hasPendingResume = true;
    try {
      await _adapter._vmService?.resume(thread.isolate.id!, step: resumeType);
    } finally {
      thread.hasPendingResume = false;
    }
  }

  FutureOr<void> setBreakpoints(
      String uri, List<SourceBreakpoint> breakpoints) async {
    // Track the breakpoints to get sent to any new isolates that start.
    _clientBreakpointsByUri[uri] = breakpoints;

    // Send the breakpoints to all existing threads.
    await Future.wait(_threadsByThreadId.values
        .map((isolate) => _sendBreakpoints(isolate.isolate, uri: uri)));
  }

  int storeData(ThreadInfo thread, Object data) {
    final id = _nextStoredDataId++;
    _storedData[id] = _StoredData(thread, data);
    return id;
  }

  FutureOr<void> _configureIsolate(vm.IsolateRef isolate) async {
    // TODO(dantup): Exception pause mode
    // TODO(dantup): setLibraryDebuggable
    await _sendBreakpoints(isolate);
  }

  FutureOr<void> _handleExit(vm.Event event) {
    final isolate = event.isolate!;
    final isolateId = isolate.id!;
    final thread = _threadsByIsolateId[isolateId];
    if (thread != null) {
      _adapter.sendEvent(
          ThreadEventBody(reason: 'exited', threadId: thread.threadId));
      _threadsByIsolateId.remove(isolateId);
      _threadsByThreadId.remove(thread.threadId);
    }
  }

  FutureOr<void> _handlePause(vm.Event event) async {
    final eventKind = event.kind;
    final isolate = event.isolate!;
    final thread = _threadsByIsolateId[isolate.id!];

    if (thread == null) {
      return;
    }

    thread.atAsyncSuspension = event.atAsyncSuspension ?? false;
    thread.paused = true;
    thread.pauseEvent = event;

    // For PausePostRequest we need to re-send all breakpoints; this happens
    // after a hot restart.
    if (eventKind == vm.EventKind.kPausePostRequest) {
      _configureIsolate(isolate);
      await resumeThread(thread.threadId);
    } else if (eventKind == vm.EventKind.kPauseStart) {
      await resumeThread(thread.threadId);
    } else {
      // PauseExit, PauseBreakpoint, PauseInterrupted, PauseException
      var reason = 'pause';

      if (eventKind == vm.EventKind.kPauseBreakpoint &&
          (event.pauseBreakpoints?.isNotEmpty ?? false)) {
        reason = 'breakpoint';
      } else if (eventKind == vm.EventKind.kPauseBreakpoint) {
        reason = 'step';
      } else if (eventKind == vm.EventKind.kPauseException) {
        reason = 'exception';
      }

      // TODO(dantup): Handle exceptions
      // final exception = event.exception;
      // if (exception != null) {
      //   (exception as InstanceWithEvaluateName).evaluateName = "$e";
      //   this.exceptionReference = this.storeData(exception);
      // }

      _adapter.sendEvent(
          StoppedEventBody(reason: reason, threadId: thread.threadId));
    }
  }

  FutureOr<void> _handleResumed(vm.Event event) {
    final isolate = event.isolate!;
    final thread = _threadsByIsolateId[isolate.id!];
    if (thread != null) {
      thread.paused = false;
      thread.pauseEvent = null;
      // TODO(dantup): Handle exceptions
      // thread.exceptionReference = 0;
    }
  }

  Future<void> _sendBreakpoints(vm.IsolateRef isolate, {String? uri}) async {
    final service = _adapter._vmService;
    if (service == null) {
      return;
    }

    final isolateId = isolate.id!;

    // If we were passed a single URI, we should send breakpoints only for that
    // (this means the request came from the client), otherwise we should send
    // all of them (because this is a new/restarting isolate).
    final uris = uri != null ? [uri] : _clientBreakpointsByUri.keys;

    for (final uri in uris) {
      // Clear existing breakpoints.
      final existingBreakpointsForIsolate =
          _vmBreakpointsByIsolateIdAndUri.putIfAbsent(isolateId, () => {});
      final existingBreakpointsForIsolateAndUri =
          existingBreakpointsForIsolate.putIfAbsent(uri, () => []);
      await Future.forEach<vm.Breakpoint>(existingBreakpointsForIsolateAndUri,
          (bp) => service.removeBreakpoint(isolateId, bp.id!));

      // Set new breakpoints.
      final newBreakpoints = _clientBreakpointsByUri[uri] ?? const [];
      await Future.forEach<SourceBreakpoint>(newBreakpoints, (bp) async {
        final vmBp = await service.addBreakpointWithScriptUri(
            isolateId, uri, bp.line,
            column: bp.column);
        existingBreakpointsForIsolateAndUri.add(vmBp);
      });
    }
  }
}

class ThreadInfo {
  final IsolateManager _manager;
  final vm.IsolateRef isolate;
  final int threadId;
  var runnable = false;
  var atAsyncSuspension = false;
  var paused = false;
  var hasPendingResume = false;
  vm.Event? pauseEvent;
  final _scripts = <String, Future<vm.Script>>{};

  ThreadInfo(this._manager, this.threadId, this.isolate);

  Future<T> getObject<T extends vm.Response>(vm.ObjRef ref) =>
      _manager.getObject<T>(isolate, ref);

  Future<vm.Script> getScript(vm.ScriptRef script) {
    // Scripts are cached since they don't change and we may send lots of
    // concurrent requests (eg. while trying to resolve location information for
    // stack frames).
    return _scripts.putIfAbsent(script.id!, () => getObject<vm.Script>(script));
  }

  int storeData(Object data) => _manager.storeData(this, data);
}

class _StoredData {
  final ThreadInfo thread;
  final Object data;

  _StoredData(this.thread, this.data);
}
