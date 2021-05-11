import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dap/src/converter.dart';
import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart' hide Event;
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';
import 'package:vm_service/vm_service.dart' as vm;

class DapCustomEventLogger implements Logger {
  final DartDebugAdapter _adapter;

  DapCustomEventLogger(this._adapter);

  @override
  void log(String message) {
    _adapter.sendCustomEvent('dart.log', message);
  }
}

/// A [DebugAdapter] implementation for running Dart CLI scripts.
class DartDebugAdapter extends DebugAdapter<DartLaunchRequestArguments> {
  late IsolateManager _isolateManager;
  late ProtocolConverter _converter;
  Process? _process;
  DartLaunchRequestArguments? args;
  File? _vmServiceInfoFile;
  StreamSubscription<FileSystemEvent>? _vmServiceInfoFileWatcher;
  final _tmpDir = Directory.systemTemp;
  vm.VmServiceInterface? vmService;
  // We normally track the pid from the VM service to terminate the VM
  // afterwards (since [_process] may be a shell), but for `flutter run` it's
  // a remote PID and therefore doesn't make sense to try and terminate.
  var _allowTerminatingVmServicePid = true;
  final _pidsToTerminate = <int>{};
  final _debuggerInitializedCompleter = Completer<void>();
  final _configurationDoneCompleter = Completer<void>();

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;

  final _subscriptions = <StreamSubscription<vm.Event>>[];

  DartDebugAdapter(LspByteStreamServerChannel channel, Logger logger)
      : super(channel, logger) {
    _isolateManager = IsolateManager(this);
    _converter = ProtocolConverter(this);
  }

  /// Completes the debugger initialization has completed. Used to delay
  /// processing isolate events while initialization is running.
  Future<void> get debuggerInitialized => _debuggerInitializedCompleter.future;

  FutureOr<void> attachRequest(
    Request request,
    AttachRequestArguments args,
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
  FutureOr<void> continueRequest(Request request, ContinueArguments args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args.threadId);
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
  FutureOr<void> evaluateRequest(Request request, EvaluateArguments args,
      void Function(EvaluateResponseBody) sendResponse) async {
    final frameId = args.frameId;
    // TODO(dantup): Special handling for clipboard/watch (see Dart-Code DAP).

    // If the frameId was supplied, it maps to an ID we provided from stored
    // data so we need to look up the isolate + frame index for it.
    ThreadInfo? thread;
    int? frameIndex;
    if (frameId != null) {
      final data = _isolateManager.getStoredData(frameId);
      if (data != null) {
        thread = data.thread;
        frameIndex = (data.data as vm.Frame).index;
      }
    }

    if (thread == null || frameIndex == null) {
      throw 'Global evaluation not currently supported';
    }

    // $e is used as a special expression that evaluates to the expression on
    // the top frame. This allows us to construct evaluateNames that evaluate
    // to the fields down the tree to support some of the debugger functionality
    // (for example Copy Value, which re-evaluates).
    final expression = args.expression.trim();
    final exceptionReference = thread.exceptionReference;
    final isExceptionExpression =
        expression == r'$e' || expression.startsWith(r'$e.');

    vm.Response? result;
    if (exceptionReference != null && isExceptionExpression) {
      final exception = _isolateManager.getStoredData(exceptionReference)?.data
          as vm.InstanceRef?;
      if (exception != null) {
        if (expression == r'$e') {
          result = exception;
        } else {
          result = await vmService?.evaluate(
              thread.isolate.id!, exception.id!, expression.substring(3),
              disableBreakpoints: true);
        }
      }
    } else {
      result = await vmService?.evaluateInFrame(
          thread.isolate.id!, frameIndex, expression,
          disableBreakpoints: true);
    }

    if (result is vm.ErrorRef) {
      // TODO(dantup): sendError(result.message);
      throw result.message ?? '<error ref>';
    } else if (result is vm.Sentinel) {
      throw result.valueAsString ?? '<collected>';
    } else if (result is vm.InstanceRef) {
      sendResponse(EvaluateResponseBody(
        result: await _converter.convertVmInstanceRefToDisplayString(
            thread, result,
            allowCallingToString: true),
        // TODO(dantup): May need to store `expression` (see Dart-Code DAP).
        variablesReference:
            isSimpleKind(result.kind) ? 0 : thread.storeData(result),
      ));
    } else {
      throw 'Unknown evaluation response type: ${result?.runtimeType}';
    }
  }

  @override
  FutureOr<void> initializeRequest(
      Request request,
      InitializeRequestArguments? args,
      void Function(Capabilities) sendResponse) async {
    // TODO(dantup): Honor things like args.linesStartAt1!
    sendResponse(Capabilities(
      exceptionBreakpointFilters: [
        ExceptionBreakpointsFilter(
          filter: 'All',
          label: 'All Exceptions',
          defaultValue: false,
        ),
        ExceptionBreakpointsFilter(
          filter: 'Unhandled',
          label: 'Uncaught Exceptions',
          defaultValue: true,
        ),
      ],
      supportsClipboardContext: true,
      // TODO(dantup): All of these...
      // supportsConditionalBreakpoints: true,
      supportsConfigurationDoneRequest: true,
      supportsDelayedStackTraceLoading: true,
      supportsEvaluateForHovers: true,
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

    this.args = args;
    final debug = args.noDebug != true;

    if (args.sendLogsToClient ?? false) {
      logger.loggers.add(DapCustomEventLogger(this));
    }

    // Don't start launching until configurationDone.
    if (!_configurationDoneCompleter.isCompleted) {
      logger.log('Waiting for configurationDone request...');
      await _configurationDoneCompleter.future;
    }

    _isolateManager.setDebugEnabled(debug);

    if (debug) {
      // TODO(dantup): For some DAs (test, Flutter) we can't use
      // write-service-info so this class will likely need splitting into two
      // (a base DA and a Dart DA).

      // If a file wasn't supplied, create a temp one with a unique name.
      // Using _tmpDir.createTempory() seems to cause errors on Windows+Linux
      // (at least on GitHub Actions) which may be caused by the folder not being
      // created fast enough and the VM (and watcher) claiming the folder does
      // not exist.
      final serviceInfoFilePath = args.vmServiceInfoFile ??
          path.join(_tmpDir.createTempSync('dart-vm-service').path, 'vm.json');
      _vmServiceInfoFile = File(serviceInfoFilePath);
    }
    final vmServiceInfoFile = _vmServiceInfoFile;

    final vmPath = path.join(args.dartSdkPath, 'bin/dart');
    final vmArgs = [
      if (debug) ...[
        '--enable-vm-service=${args.vmServicePort ?? 0}',
        '--pause_isolates_on_start=true',
      ],
      if (debug && vmServiceInfoFile != null) ...[
        '-DSILENT_OBSERVATORY=true',
        '--write-service-info=${Uri.file(vmServiceInfoFile.path)}'
      ],
      if (args.enableAsserts != false) '--enable-asserts',
      ...?args.vmAdditionalArgs,
    ];

    _vmServiceInfoFileWatcher = vmServiceInfoFile?.parent
        .watch(events: FileSystemEvent.all)
        .where((event) => event.path == vmServiceInfoFile.path)
        .listen(_handleVmServiceInfoEvent, onError: (e) {
      logger.log('Ignoring exception from watcher: $e');
    });

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
  FutureOr<void> nextRequest(Request request, NextArguments args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args.threadId, vm.StepOption.kOver);
    sendResponse(null);
  }

  @override
  FutureOr<void> scopesRequest(Request request, ScopesArguments args,
      void Function(ScopesResponseBody) sendResponse) {
    final scopes = <Scope>[];

    // For local variables, we can just reuse the frameId as variablesReference
    // as variablesRequest handles stored data of type `Frame`.
    scopes.add(Scope(
      name: 'Variables',
      presentationHint: 'locals',
      variablesReference: args.frameId,
      expensive: false,
    ));

    // If the top frame has an exception, add a section for that.
    final data = _isolateManager.getStoredData(args.frameId);
    final exceptionReference = data?.thread.exceptionReference;
    if (exceptionReference != null) {
      scopes.add(Scope(
        name: 'Exceptions',
        variablesReference: exceptionReference,
        expensive: false,
      ));
    }

    sendResponse(ScopesResponseBody(scopes: scopes));
  }

  @override
  FutureOr<void> setBreakpointsRequest(
      Request request,
      SetBreakpointsArguments args,
      void Function(SetBreakpointsResponseBody) sendResponse) async {
    final breakpoints = args.breakpoints ?? [];

    final path = args.source.path;
    final name = args.source.name;
    final uri = path != null ? Uri.file(path).toString() : name!;

    await _isolateManager.setBreakpoints(uri, breakpoints);

    // TODO(dantup): Handle breakpoint resolution rather than pretending all
    // breakpoints are verified immediately.
    sendResponse(SetBreakpointsResponseBody(
      breakpoints: breakpoints.map((e) => Breakpoint(verified: true)).toList(),
    ));
  }

  @override
  FutureOr<void> setExceptionBreakpointsRequest(
      Request request,
      SetExceptionBreakpointsArguments args,
      void Function(SetExceptionBreakpointsResponseBody) sendResponse) async {
    final mode = args.filters.contains('All')
        ? 'All'
        : args.filters.contains('Unhandled')
            ? 'Unhandled'
            : 'None';

    await _isolateManager.setExceptionPauseMode(mode);

    sendResponse(SetExceptionBreakpointsResponseBody());
  }

  @override
  FutureOr<void> stackTraceRequest(Request request, StackTraceArguments args,
      void Function(StackTraceResponseBody) sendResponse) async {
    // How many "extra" frames we claim to have so that the client will
    // let the user fetch them in batches rather than all at once.
    const stackFrameBatchSize = 20;
    final threadId = args.threadId;
    final thread = _isolateManager._threadsByThreadId[threadId];
    final topFrame = thread?.pauseEvent?.topFrame;
    final startFrame = args.startFrame ?? 0;
    final numFrames = args.levels ?? 0;
    var totalFrames = 1;

    if (thread == null) {
      throw 'No thread with threadId $threadId';
    }

    if (!thread.paused) {
      throw 'Thread $threadId is not paused';
    }

    final stackFrames = <StackFrame>[];
    // If the request is only for the top frame, we can satisfy it from the
    // threads `pauseEvent.topFrame`.
    if (startFrame == 0 && numFrames == 1 && topFrame != null) {
      totalFrames = 1 + stackFrameBatchSize;
      stackFrames.add(await _converter
          .convertVmToDapStackFrame(thread, topFrame, isTopFrame: true));
    } else {
      // Otherwise, send the request on to the VM.
      final limit = startFrame + numFrames;
      final stack = await vmService?.getStack(thread.isolate.id!, limit: limit);
      final frames = stack?.frames;

      if (stack != null && frames != null) {
        // When the call stack is truncated, we always add [stackFrameBatchSize]
        // to the count, indicating to the client there are more frames and
        // the size of the batch they should request when "loading more".
        totalFrames = (stack.truncated ?? false)
            ? frames.length + stackFrameBatchSize
            : frames.length;

        final frameSubset = frames.sublist(startFrame);
        stackFrames.addAll(await Future.wait(frameSubset.mapIndexed(
            (index, frame) async => _converter.convertVmToDapStackFrame(
                thread, frame,
                isTopFrame: startFrame == 0 && index == 0))));
      }
    }

    sendResponse(StackTraceResponseBody(
        stackFrames: stackFrames, totalFrames: totalFrames));
  }

  @override
  FutureOr<void> stepInRequest(Request request, StepInArguments args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args.threadId, vm.StepOption.kInto);
    sendResponse(null);
  }

  @override
  FutureOr<void> stepOutRequest(Request request, StepOutArguments args,
      void Function(void) sendResponse) async {
    await _isolateManager.resumeThread(args.threadId, vm.StepOption.kOut);
    sendResponse(null);
  }

  @override
  FutureOr<void> terminateRequest(Request request, TerminateArguments? args,
      void Function(void) sendResponse) async {
    _subscriptions.forEach((sub) => sub.cancel());
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
    final threads = _isolateManager.threads
        .map((t) =>
            Thread(id: t.threadId, name: t.isolate.name ?? '<unnamed isolate>'))
        .toList();
    sendResponse(ThreadsResponseBody(threads: threads));
  }

  @override
  FutureOr<void> variablesRequest(Request request, VariablesArguments args,
      void Function(VariablesResponseBody) sendResponse) async {
    final childStart = args.start;
    final childCount = args.count;
    final storedData = _isolateManager.getStoredData(args.variablesReference);
    if (storedData == null) {
      throw 'variablesReference is no longer valid';
    }
    final thread = storedData.thread;
    final data = storedData.data;
    final vmData = data is vm.Response ? data : null;
    final variables = <Variable>[];

    if (vmData is vm.Frame) {
      final vars = vmData.vars;
      if (vars != null) {
        variables.addAll(await Future.wait(vars.mapIndexed(
            (index, variable) async => _converter.convertVmResponseToVariable(
                thread, variable.value,
                name: variable.name,
                allowCallingToString: index <= maxToStringsPerEvaluation))));
      }
    } else if (vmData is vm.MapAssociation) {
      // TODO(dantup): Maps
    } else if (vmData is vm.ObjRef) {
      final object =
          await _isolateManager.getObject(storedData.thread.isolate, vmData);

      if (object is vm.Sentinel) {
        variables.add(Variable(
          name: '<eval error>',
          value: object.valueAsString.toString(),
          variablesReference: 0,
        ));
      } else if (object is vm.Instance) {
        // TODO(dantup): evaluateName
        // in the case where args.variablesReference == thread.exceptionReference,
        // it should be "$e"..
        variables.addAll(await _converter.convertVmInstanceToVariablesList(
            thread, object,
            startItem: childStart, numItems: childCount));
      } else {
        variables.add(Variable(
          name: '<eval error>',
          value: object.runtimeType.toString(),
          variablesReference: 0,
        ));
      }
    }

    variables.sortBy((v) => v.name);

    sendResponse(VariablesResponseBody(variables: variables));
  }

  Future<void> _connectDebugger(Uri uri) async {
    uri = _normaliseVmServiceUri(uri);
    logger.log('Connecting to debugger at $uri');
    sendEvent(
      OutputEventBody(
          category: 'console', output: 'Connecting to VM Service at $uri\n'),
    );
    final vmService = await _vmServiceConnectUri(
      uri.toString(),
      log: VmLogger(logger),
    );
    logger.log('Connected to debugger at $uri!');
    // TODO(dantup): VS Code currently depends on a custom dart.debuggerUris
    // event to notify it of VM Services that become available. If this is still
    // required, it will need implementing here.
    this.vmService = vmService;

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

    _debuggerInitializedCompleter.complete();
  }

  void _handleDebugEvent(vm.Event event) {
    _isolateManager.handleEvent(event);
  }

  void _handleExitCode(int code) {
    final codeSuffix = code == 0 ? '' : ' ($code)';
    logger.log('Process exited ($code)');
    sendEvent(
      // Always add a newline since the last printed text might not have had
      // one.
      OutputEventBody(category: 'console', output: '\nExited$codeSuffix.'),
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
    sendEvent(OutputEventBody(category: 'stderr', output: utf8.decode(data)));
  }

  void _handleStderrEvent(vm.Event event) {}

  void _handleStdout(List<int> data) {
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
  final bool? evaluateGettersInDebugViews;
  final bool? evaluateToStringInDebugViews;

  /// Whether to send debug logging to clients in a custom `dart.log` event. This
  /// is used both by the out-of-process tests to ensure the logs contain enough
  /// information to track down issues, but also by Dart-Code to capture VM
  /// service traffic in a unified log file.
  final bool? sendLogsToClient;

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
    this.evaluateGettersInDebugViews,
    this.evaluateToStringInDebugViews,
    this.sendLogsToClient,
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
        evaluateGettersInDebugViews =
            obj['evaluateGettersInDebugViews'] as bool?,
        evaluateToStringInDebugViews =
            obj['evaluateToStringInDebugViews'] as bool?,
        sendLogsToClient = obj['sendLogsToClient'] as bool?,
        super.fromMap(obj);

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        'dartSdkPath': dartSdkPath,
        'program': program,
        if (args != null) 'args': args,
        if (cwd != null) 'cwd': cwd,
        if (vmServiceInfoFile != null) 'vmServiceInfoFile': vmServiceInfoFile,
        if (vmServicePort != null) 'vmServicePort': vmServicePort,
        if (vmAdditionalArgs != null) 'vmAdditionalArgs': vmAdditionalArgs,
        if (enableAsserts != null) 'enableAsserts': enableAsserts,
        if (evaluateGettersInDebugViews != null)
          'evaluateGettersInDebugViews': evaluateGettersInDebugViews,
        if (evaluateToStringInDebugViews != null)
          'evaluateToStringInDebugViews': evaluateToStringInDebugViews,
        if (sendLogsToClient != null) 'sendLogsToClient': sendLogsToClient,
      };

  static DartLaunchRequestArguments fromJson(Map<String, Object?> obj) =>
      DartLaunchRequestArguments.fromMap(obj);
}

/// Manages state of Isolates (called Threads by the DAP protocol).
///
/// Handles incoming Isolate and Debug events to track the lifetime of isolates
/// and updating breakpoints for each isolate as necessary.
class IsolateManager {
  final DartDebugAdapter _adapter;
  final Map<String, Completer<void>> _isolateRegistrations = {};
  final Map<String, ThreadInfo> _threadsByIsolateId = {};
  final Map<int, ThreadInfo> _threadsByThreadId = {};
  int _nextThreadNumber = 1;

  /// Whether debugging is enabled. This must be set before any isolates are
  /// spawned and controls whether breakpoints or exception pause modes are sent
  /// to the VM.
  var _debug = false;

  /// Tracks breakpoints last provided by the client so they can be sent to new
  /// isolates that appear after initial breakpoints are set.
  final Map<String, List<SourceBreakpoint>> _clientBreakpointsByUri = {};

  /// Tracks breakpoints created in the VM, so they can be removed when the
  /// editor sends new breakpoints (currently the editor just sends a new list
  /// and not requests to add/remove).
  final Map<String, Map<String, List<vm.Breakpoint>>>
      _vmBreakpointsByIsolateIdAndUri = {};

  var _exceptionPauseMode = 'None';

  var _nextStoredDataId = 1;

  /// A store of data indexed by a number that is used for round tripping
  /// references to the client (which only accepts ints). For example stack
  /// frames may be sent with a "sourceReference" that relates to a scriptRef,
  /// which is sent back to us in sourceRequest to get more information about
  /// the script.
  final _storedData = <int, _StoredData>{};

  IsolateManager(this._adapter);

  /// A list of all current active isolates.
  ///
  /// When isolates exit, they will no longer be returned in this list, although
  /// due to the async nature, it's not guaranteed that threads in this list have
  /// not exited between accessing this list and trying to use the results.
  List<ThreadInfo> get threads => _threadsByIsolateId.values.toList();

  Future<T> getObject<T extends vm.Response>(
      vm.IsolateRef isolate, vm.ObjRef object) async {
    final res = await _adapter.vmService?.getObject(isolate.id!, object.id!);
    return res as T;
  }

  /// Retrieves some basic data indexed by an integer for use in "reference"
  /// fields that are round-tripped to the client.
  _StoredData? getStoredData(int id) {
    return _storedData[id];
  }

  /// Handles Isolate and Debug events
  FutureOr<void> handleEvent(vm.Event event) async {
    final isolateId = event.isolate?.id;
    if (isolateId == null) {
      return;
    }

    // Delay processed any events until the debugger initialisation has finished
    // running, as events may arrive (for ex. IsolateRunnable) while it's doing
    // is own initialisation that this may interfere with.
    await _adapter.debuggerInitialized;

    final eventKind = event.kind;
    if (eventKind == vm.EventKind.kIsolateStart ||
        eventKind == vm.EventKind.kIsolateRunnable) {
      await registerIsolate(event.isolate!, eventKind!);
    }

    // Ensure the thread registration has completed before trying to process
    // any other events, otherwise we may have races:
    //
    // - IsolateRunnable
    //   (registration asynchronously sets up breakpoints)
    // - PauseStart
    //   (if this happens before the registration completes, we may resume before
    //   the breakpoints were set up).
    await _isolateRegistrations[isolateId]?.future;

    if (eventKind == vm.EventKind.kIsolateExit) {
      await _handleExit(event);
    } else if (eventKind?.startsWith('Pause') ?? false) {
      await _handlePause(event);
    } else if (eventKind == vm.EventKind.kResume) {
      await _handleResumed(event);
    }
  }

  /// Registers a new isolate that exists at startup, or has subsequently been
  /// created.
  ///
  /// New isolates will be configured with the correct pause-exception behaviour,
  /// libraries will be marked as debuggable if appropriate, and breakpoints
  /// sent.
  FutureOr<void> registerIsolate(
      vm.IsolateRef isolate, String eventKind) async {
    // Ensure the completer is set up before doing any async work, so future
    // events can wait on it.
    final registrationCompleter =
        _isolateRegistrations.putIfAbsent(isolate.id!, () => Completer<void>());

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
      registrationCompleter.complete();
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

  /// Resumes (or steps) an isolate using its client [threadId].
  ///
  /// If the isolate is not paused, or already has a pending resume request
  /// in-flight, a request will not be sent.
  ///
  /// If the isolate is paused at an async suspension and the [resumeType] is
  /// [vm.StepOption.kOver], a [StepOption.kOverAsyncSuspension] step will be
  /// sent instead.
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
      await _adapter.vmService?.resume(thread.isolate.id!, step: resumeType);
    } finally {
      thread.hasPendingResume = false;
    }
  }

  /// Records breakpoints for [uri]. All existing isolates breakpoints will be
  /// updated to match the new set.
  FutureOr<void> setBreakpoints(
      String uri, List<SourceBreakpoint> breakpoints) async {
    // Track the breakpoints to get sent to any new isolates that start.
    _clientBreakpointsByUri[uri] = breakpoints;

    // Send the breakpoints to all existing threads.
    await Future.wait(_threadsByThreadId.values
        .map((isolate) => _sendBreakpoints(isolate.isolate, uri: uri)));
  }

  /// Sets whether debugging is enabled. If not, request to send breakpoints or
  /// exception pause mode will be dropped. Other functionality (handling pause
  /// events, resuming, etc.) will all still function.
  ///
  /// This is used in Flutter where a VM connection is available even if the
  /// user is "running without debugging" to allow functionality that depends on
  /// VM Services.
  void setDebugEnabled(bool debug) {
    _debug = debug;
  }

  /// Records exception pause mode as one of 'None', 'Unhandled' or 'All'. All
  /// existing isolates will be updated to reflect the new setting.
  FutureOr<void> setExceptionPauseMode(String mode) async {
    _exceptionPauseMode = mode;

    // Send to all existing threads.
    await Future.wait(_threadsByThreadId.values
        .map((isolate) => _sendExceptionPauseMode(isolate.isolate)));
  }

  /// Stores some basic data indexed by an integer for use in "reference" fields
  /// that are round-tripped to the client.
  int storeData(ThreadInfo thread, Object data) {
    final id = _nextStoredDataId++;
    _storedData[id] = _StoredData(thread, data);
    return id;
  }

  /// Configures a new isolate, setting it's exception-pause mode, which
  /// libraries are debuggable, and sending all breakpoints.
  FutureOr<void> _configureIsolate(vm.IsolateRef isolate) async {
    await Future.wait([
      // TODO(dantup): setLibraryDebuggable
      _sendExceptionPauseMode(isolate),
      _sendBreakpoints(isolate),
    ], eagerError: true);
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

  /// Handles a pause event.
  ///
  /// For [vm.EventKind.kPausePostRequest] which occurs after a restart, the isolate
  /// will be re-configured (pause-exception behaviour, debuggable libraries,
  /// breakpoints) and then resumed.
  ///
  /// For [vm.EventKind.kPauseStart], the isolate will be resumed.
  ///
  /// For breakpoints with conditions that are not met and for logpoints, the
  /// isolate will be automatically resumed.
  ///
  /// For all other pause types, the isolate will remain paused and a
  /// corresponding "Stopped" event sent to the editor.
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

      final exception = event.exception;
      if (exception != null) {
        thread.exceptionReference = thread.storeData(exception);
      }

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
      thread.exceptionReference = null;
    }
  }

  /// Sets breakpoints for an individual isolate.
  ///
  /// If [uri] is provided, only breakpoints for that URI will be sent (used
  /// when breakpoints are modified for a single file in the editor). Otherwise
  /// all known editor breakpoints will be sent (used for newly-created isoaltes).
  Future<void> _sendBreakpoints(vm.IsolateRef isolate, {String? uri}) async {
    final service = _adapter.vmService;
    if (!_debug || service == null) {
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

  /// Sets the exception pause mode for an individual isolate.
  Future<void> _sendExceptionPauseMode(vm.IsolateRef isolate) async {
    final service = _adapter.vmService;
    if (!_debug || service == null) {
      return;
    }

    await service.setExceptionPauseMode(isolate.id!, _exceptionPauseMode);
  }
}

/// Holds state for a single Isolate/Thread.
class ThreadInfo {
  final IsolateManager _manager;
  final vm.IsolateRef isolate;
  final int threadId;
  var runnable = false;
  var atAsyncSuspension = false;
  int? exceptionReference;
  var paused = false;

  // The most recent pauseEvent for this isolate.
  vm.Event? pauseEvent;

  // A cache of requests (Futures) to fetch scripts, so that multiple requests
  // that require scripts (for example looking up locations for stack frames from
  // tokenPos) can share the same response.
  final _scripts = <String, Future<vm.Script>>{};

  /// Whether this isolate has an in-flight resume request that has not yet
  /// been responded to.
  var hasPendingResume = false;

  ThreadInfo(this._manager, this.threadId, this.isolate);

  Future<T> getObject<T extends vm.Response>(vm.ObjRef ref) =>
      _manager.getObject<T>(isolate, ref);

  Future<vm.Script> getScript(vm.ScriptRef script) {
    // Scripts are cached since they don't change and we may send lots of
    // concurrent requests (eg. while trying to resolve location information for
    // stack frames).
    return _scripts.putIfAbsent(script.id!, () => getObject<vm.Script>(script));
  }

  /// Stores some basic data indexed by an integer for use in "reference" fields
  /// that are round-tripped to the client.
  int storeData(Object data) => _manager.storeData(this, data);
}

class _StoredData {
  final ThreadInfo thread;
  final Object data;

  _StoredData(this.thread, this.data);
}
