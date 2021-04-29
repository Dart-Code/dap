import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dap/src/debug_adapter.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart' hide Event;
import 'package:dap/src/logging.dart';
import 'package:dap/src/temp_borrowed_from_analysis_server/lsp_byte_stream_channel.dart';
import 'package:path/path.dart' as path;
import 'package:pedantic/pedantic.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

class DartDebugAdapter extends DebugAdapter<DartLaunchRequestArguments> {
  late IsolateManager _isolateManager;
  Process? _process;
  var _debug = false;
  File? _vmServiceInfoFile;
  StreamSubscription<FileSystemEvent>? _vmServiceInfoFileWatcher;
  final _tmpDir = Directory.systemTemp;
  VmServiceInterface? _vmService;
  // We normally track the pid from the VM service to terminate the VM
  // afterwards (since [_process] may be a shell), but for `flutter run` it's
  // a remote PID and therefore doesn't make sense to try and terminate.
  var _allowTerminatingVmServicePid = true;
  final _pidsToTerminate = <int>{};
  final _configurationDoneCompleter = Completer<void>();

  @override
  final parseLaunchArgs = DartLaunchRequestArguments.fromJson;

  // TODO(dantup): Ensure this is cleaned up!
  final _subscriptions = <StreamSubscription<Event>>[];

  DartDebugAdapter(LspByteStreamServerChannel channel, Logger logger)
      : super(channel, logger) {
    _isolateManager = IsolateManager(this);
  }

  Future<void> attachRequest(
    Request request,
    AttachRequestArguments? args,
    void Function(void) sendResponse,
  ) async {
    // Reminder: Don't start launching until configurationDone.
    await _configurationDoneCompleter.future;
    throw UnimplementedError();
  }

  @override
  Future<void> configurationDoneRequest(
      Request request,
      ConfigurationDoneArguments? args,
      void Function(void) sendResponse) async {
    _configurationDoneCompleter.complete();
    sendResponse(null);
  }

  @override
  Future<void> disconnectRequest(Request request, DisconnectArguments? args,
      void Function(void) sendResponse) async {
    // TODO(dantup): implement disconnectRequest
    throw UnimplementedError();
  }

  @override
  Future<void> initializeRequest(
      Request request,
      InitializeRequestArguments? args,
      void Function(Capabilities) sendResponse) async {
    sendResponse(Capabilities(
      supportsConfigurationDoneRequest: true,
    ));

    // This must only be sent AFTER the response!
    sendEvent(InitializedEventBody());
  }

  @override
  Future<void> launchRequest(
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
        '--enable-vm-service=${args.vmServicePort}',
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

  FutureOr<void> resumeIsolate(IsolateRef isolateRef) =>
      _vmService?.resume(isolateRef.id!);

  Future<void> _connectDebugger(Uri uri) async {
    uri = _normaliseVmServiceUri(uri);
    logger.log('Connecting to debugger at $uri');
    sendEvent(
      OutputEventBody(
          category: 'console', output: 'Connecting to VM Service at $uri$eol'),
    );
    // TODO(dantup): Support logging of VM traffic.
    final vmService = await vmServiceConnectUri(
      uri.toString(),
      log: VmLogger(logger),
    );
    logger.log('Connected to debugger at $uri!');
    _vmService = vmService;

    // TODO(dantup): VS Code currently depends on a custom dart.debuggerUris
    // event to notify it of VM Services that become available. If this is still
    // required, it will need implementing here.
    _subscriptions.addAll([
      vmService.onIsolateEvent.listen(_handleIsolateEvent),
      vmService.onExtensionEvent.listen(_handleExtensionEvent),
      vmService.onDebugEvent.listen(_handleDebugEvent),
      vmService.onServiceEvent.listen(_handleServiceEvent),
      vmService.onLoggingEvent.listen(_handleLoggingEvent),
      vmService.onStdoutEvent.listen(_handleStdoutEvent),
      vmService.onStderrEvent.listen(_handleStderrEvent),
    ]);

    final vm = await vmService.getVM();
    logger.log('Connected to ${vm.name} on ${vm.operatingSystem}');

    // If we own this process (we launched it, didn't attach), then we should
    // keep a ref to this process to terminate when we quit. This avoids issues
    // where our process is a shell (eg. flutter shell script) and the kill
    // signal isn't passed on correctly.
    // See: https://github.com/Dart-Code/Dart-Code/issues/907
    if (_allowTerminatingVmServicePid && _process != null) {
      final pid = vm.pid;
      if (pid != null) {
        _pidsToTerminate.add(pid);
      }
    }

    // Process any isolates that may have been created before the streams above
    // were set up.
    final existingIsolateRefs = vm.isolates;
    final existingIsolates = existingIsolateRefs != null
        ? await Future.wait(existingIsolateRefs
            .map((isolateRef) => isolateRef.id)
            .whereNotNull()
            .map(vmService.getIsolate))
        : <Isolate>[];
    await Future.wait(existingIsolates.map((isolate) async {
      await _isolateManager.registerThread(isolate);
      if (isolate.pauseEvent?.kind?.startsWith('Pause') ?? false) {
        await _isolateManager.handleEvent(isolate.pauseEvent!);
      } else {
        await resumeIsolate(isolate);
      }
    }));
  }

  void _handleDebugEvent(Event event) {}

  void _handleExitCode(int code) {
    final codeSuffix = code == 0 ? '' : ' ($code)';
    sendEvent(
      // Always add a newline since the last printed text might not have had
      // one.
      OutputEventBody(category: 'console', output: '${eol}Exited$codeSuffix.'),
    );
    sendEvent(TerminatedEventBody());
  }

  void _handleExtensionEvent(Event event) {}

  void _handleIsolateEvent(Event event) {
    _isolateManager.handleEvent(event);
  }

  void _handleLoggingEvent(Event event) {}

  void _handleServiceEvent(Event event) {}

  void _handleStderr(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stderr', output: utf8.decode(data)));
  }

  void _handleStderrEvent(Event event) {}

  void _handleStdout(List<int> data) {
    // TODO(dantup): Is it safe to assume UTF8?
    sendEvent(OutputEventBody(category: 'stdout', output: utf8.decode(data)));
  }

  void _handleStdoutEvent(Event event) {}

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

class IsolateInfo {
  final IsolateRef isolate;
  final int threadNumber;
  var runnable = false;

  IsolateInfo(this.threadNumber, this.isolate);
}

class IsolateManager {
  final DartDebugAdapter _adapter;
  final Map<String, IsolateInfo> _isolatesByIsolateId = {};
  final Map<int, IsolateInfo> _isolatesByThreadId = {};
  int _nextThreadNumber = 1;

  IsolateManager(this._adapter);

  FutureOr<void> handleEvent(Event event) async {
    if (event.isolate?.id == null) {
      // TODO(dantup): Log?
      return;
    }

    if (event.kind == EventKind.kIsolateStart ||
        event.kind == EventKind.kIsolateRunnable) {
      // TODO(dantup): Veryify this case is sound for these events
      await registerThread(event.isolate as Isolate);
      _adapter.resumeIsolate(event.isolate!);
    } else if (event.kind == EventKind.kIsolateExit) {
      await _handleExit(event);
    } else if (event.kind?.startsWith('Pause') ?? false) {
      await _handlePause(event);
    }
  }

  FutureOr<void> registerThread(Isolate isolate) async {
    final info = _isolatesByIsolateId.putIfAbsent(isolate.id!, () {
      final info = IsolateInfo(_nextThreadNumber++, isolate);
      _isolatesByThreadId[info.threadNumber] = info;
      _adapter.sendEvent(
          ThreadEventBody(reason: 'started', threadId: info.threadNumber));
      return info;
    });

    // If it's just become runnable (IsolateRunnable), then set up breakpoints
    // and exception pause mode.
    if (isolate.runnable == true && !info.runnable) {
      info.runnable = true;
      await _configureThread();
    }
  }

  FutureOr<void> _configureThread() async {
    // TODO(dantup): Exception pause mode
    // TODO(dantup): setLibraryDebuggable
    // TODO(dantup): Breakpoints
  }

  FutureOr<void> _handleExit(Event event) {}

  FutureOr<void> _handlePause(Event event) {
    // For PausePostRequest we need to re-send all breakpoints; this happens
    // after a hot restart.
    if (event.kind == EventKind.kPausePostRequest) {
      _configureThread();
      _adapter.resumeIsolate(event.isolate!);
    } else if (event.kind == EventKind.kPauseStart) {
      _adapter.resumeIsolate(event.isolate!);
    } else {
      // PauseStart, PauseExit, PauseBreakpoint, PauseInterrupted, PauseException

      // TODO(dantup): !
    }
  }
}
