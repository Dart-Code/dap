import 'dart:async';
import 'dart:io';

import 'package:dap/src/debug_adapter_protocol_generated.dart' as dap;
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart' as vm;

import 'adapters/dart.dart';

class ProtocolConverter {
  final DartDebugAdapter _adapter;

  ProtocolConverter(this._adapter);

  String convertToRelativePath(String sourcePath) {
    if (_adapter.cwd == null) {
      return sourcePath;
    }
    final rel = path.relative(sourcePath, from: _adapter.cwd);
    return !rel.startsWith('..') ? rel : sourcePath;
  }

  String convertVmInstanceRefToDisplayString(vm.InstanceRef ref) {
    if (ref.kind == 'String' || ref.valueAsString != null) {
      var stringValue = ref.valueAsString.toString();
      if (ref.valueAsStringIsTruncated ?? false) {
        stringValue = '$stringValue…';
      }
      if (ref.kind == 'String') {
        stringValue = '"$stringValue"';
      }
      return stringValue;
    } else if (ref.kind == 'List') {
      return 'List (${ref.length} ${ref.length == 1 ? "item" : "items"})';
    } else if (ref.kind == 'Map') {
      return 'Map (${ref.length} ${ref.length == 1 ? "item" : "items"})';
    } else if (ref.kind == 'Type') {
      return 'Type (${ref.name})';
    } else {
      return '<unknown ${ref.kind}>';
    }
  }

  FutureOr<dap.StackFrame> convertVmToDapStackFrame(
      ThreadInfo thread, vm.Frame frame,
      {required bool isTopFrame, int? firstAsyncMarkerIndex}) async {
    const unoptimizedPrefix = '[Unoptimized] ';
    final frameId = thread.storeData(frame);

    if (frame.kind == vm.FrameKind.kAsyncSuspensionMarker) {
      return dap.StackFrame(
        id: frameId,
        name: '<asynchronous gap>',
        presentationHint: 'label',
        line: 0,
        column: 0,
      );
    }

    final codeName = frame.code?.name;
    final frameName = codeName != null
        ? (codeName.startsWith(unoptimizedPrefix)
            ? codeName.substring(unoptimizedPrefix.length)
            : codeName)
        : '<unknown>';

    final location = frame.location;
    if (location == null) {
      return dap.StackFrame(
        id: frameId,
        name: frameName,
        presentationHint: 'subtle',
        line: 0,
        column: 0,
      );
    }

    final scriptRef = location.script;
    final tokenPos = location.tokenPos;
    final uri = scriptRef?.uri;
    final sourcePath = uri != null ? convertVmUriToSourcePath(uri) : null;
    var canShowSource = sourcePath != null && File(sourcePath).existsSync();

    // Download the source if from a "dart:" uri.
    int? sourceReference;
    if (uri != null &&
        (uri.startsWith('dart:') || uri.startsWith('org-dartlang-app:')) &&
        scriptRef != null) {
      sourceReference = thread.storeData(scriptRef);
      canShowSource = true;
    }

    // TODO(dantup): Try to resolve line and column information from the tokenPos.
    var line = 0, col = 0;
    if (scriptRef != null && tokenPos != null) {
      try {
        final script = await thread.getScript(scriptRef);
        line = script.getLineNumberFromTokenPos(tokenPos) ?? 0;
        col = script.getColumnNumberFromTokenPos(tokenPos) ?? 0;
      } catch (_) {
        // TODO(dantup): log?
      }
    }

    return dap.StackFrame(
      id: frameId,
      name: frameName,
      source: canShowSource
          ? dap.Source(
              name:
                  sourcePath != null ? convertToRelativePath(sourcePath) : uri,
              path: sourcePath,
              sourceReference: sourceReference,
              origin: null,
              adapterData: location.script)
          : null,
      line: line, column: col,
      // We can only restart from frames that are not the top frame and are
      // before the first async marker frame.
      canRestart: !isTopFrame &&
          (firstAsyncMarkerIndex == null ||
              frame.index! < firstAsyncMarkerIndex),
    );
  }

  String? convertVmUriToSourcePath(String uri) {
    if (uri.startsWith('file://')) {
      return Uri.parse(uri).toFilePath();
    } else if (uri.startsWith('package:')) {
      // TODO(dantup): Handle mapping package: uris ?
      return null;
    } else {
      return null;
    }
  }
}
