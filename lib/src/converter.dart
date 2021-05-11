import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dap/src/debug_adapter_protocol_generated.dart' as dap;
import 'package:path/path.dart' as path;
import 'package:vm_service/vm_service.dart' as vm;

import 'adapters/dart.dart';

/// Whether [kind] is a simple kind, and does not need to be mapped to a variable.
bool isSimpleKind(String? kind) {
  return kind == 'String' ||
      kind == 'Bool' ||
      kind == 'Int' ||
      kind == 'Num' ||
      kind == 'Double' ||
      kind == 'Null' ||
      kind == 'Closure';
}

class ProtocolConverter {
  final DartDebugAdapter _adapter;

  ProtocolConverter(this._adapter);

  String convertToRelativePath(String sourcePath) {
    final cwd = _adapter.args?.cwd;
    if (cwd == null) {
      return sourcePath;
    }
    final rel = path.relative(sourcePath, from: cwd);
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
    } else if (ref.kind == 'PlainInstance') {
      return ref.classRef?.name ?? '<unknown instance>';
    } else if (ref.kind == 'List') {
      return 'List (${ref.length} ${ref.length == 1 ? "item" : "items"})';
    } else if (ref.kind == 'Map') {
      return 'Map (${ref.length} ${ref.length == 1 ? "item" : "items"})';
    } else if (ref.kind == 'Type') {
      return 'Type (${ref.name})';
    } else {
      return ref.kind ?? '<unknown result>';
    }
  }

  /// Fetches a [vm.Instance] for a [vm.InstanceRef] and converts it to a
  /// variables list.
  Future<List<dap.Variable>> convertVmInstanceRefToVariablesList(
      ThreadInfo thread, vm.InstanceRef instance,
      {int startItem = 0, int? numItems}) async {
    final response = await thread.getObject(instance);
    if (response is vm.Instance) {
      return convertVmInstanceToVariablesList(thread, response);
    } else {
      return [convertVmResponseToVariable(response)];
    }
  }

  /// Converts a [vm.Instace] to a list of [dap.Variable]s, one for each
  /// field/member/element/association.
  Future<List<dap.Variable>> convertVmInstanceToVariablesList(
      ThreadInfo thread, vm.Instance instance,
      {int? startItem = 0, int? numItems}) async {
    final elements = instance.elements;
    final associations = instance.associations;
    final fields = instance.fields;

    if (isSimpleKind(instance.kind)) {
      return [convertVmResponseToVariable(instance)];
    } else if (elements != null) {
      final start = startItem ?? 0;
      return elements
          .cast<vm.Response>()
          .sublist(start, numItems != null ? start + numItems : null)
          .mapIndexed((index, response) =>
              convertVmResponseToVariable(response, name: '${start + index}'))
          .toList();
    } else if (associations != null) {
      final start = startItem ?? 0;
      return associations
          .sublist(start, numItems != null ? start + numItems : null)
          .mapIndexed((index, mapEntry) {
        final keyDisplay = convertVmResponseToDisplayString(mapEntry.key);
        final valueDisplay = convertVmResponseToDisplayString(mapEntry.value);
        return dap.Variable(
          name: '${start + index}',
          value: '$keyDisplay -> $valueDisplay',
          variablesReference: thread.storeData(mapEntry),
        );
      }).toList();
    } else if (fields != null) {
      final variables = fields
          .map((field) => convertVmResponseToVariable(field.value,
              name: field.decl?.name ?? '<unnamed field>'))
          .toList();

      // Stitch in getters if enabled.
      final service = _adapter.vmService;
      if (service != null &&
          (_adapter.args?.evaluateGettersInDebugViews ?? false)) {
        // Collect getter names for this instances class and its supers.
        final getterNames =
            await _getterNamesForHierarchy(thread, instance.classRef);

        // Evaluate each getter.
        final getterResults = await Future.wait(getterNames.map((name) async {
          final response =
              await service.evaluate(thread.isolate.id!, instance.id!, name);
          // Convert results to variables.
          return convertVmResponseToVariable(response, name: name);
        }));

        variables.addAll(getterResults);
      }

      variables.sortBy((v) => v.name);
      return variables;
    } else {
      // TODO(dantup): !
      return [];
    }
  }

  String convertVmResponseToDisplayString(vm.Response response) {
    if (response is vm.InstanceRef) {
      return convertVmInstanceRefToDisplayString(response);
    } else if (response is vm.Sentinel) {
      return '<sentinel>';
    } else {
      return '<unknown: ${response.type}>';
    }
  }

  /// Converts a [vm.Response] directly to a [dap.Variable].
  dap.Variable convertVmResponseToVariable(vm.Response response,
      {String? name}) {
    if (response is vm.InstanceRef) {
      return dap.Variable(
        name: name ?? response.kind.toString(),
        value: convertVmResponseToDisplayString(response),
        variablesReference: 0,
      );
    } else if (response is vm.Sentinel) {
      return dap.Variable(
        name: '<sentinel>',
        value: response.valueAsString.toString(),
        variablesReference: 0,
      );
    } else {
      return dap.Variable(
        name: '<error>',
        value: response.runtimeType.toString(),
        variablesReference: 0,
      );
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

  Future<Set<String>> _getterNamesForHierarchy(
      ThreadInfo thread, vm.ClassRef? classRef) async {
    final getterNames = <String>{};
    final service = _adapter.vmService;
    while (service != null && classRef != null) {
      final classResponse =
          await service.getObject(thread.isolate.id!, classRef.id!);
      if (classResponse is! vm.Class) {
        break;
      }
      final functions = classResponse.functions;
      if (functions != null) {
        final instanceFields = functions.where((f) =>
            // TODO(dantup): Is there a better way to get just the getters?
            f.json?['_kind'] == 'GetterFunction' &&
            !(f.isStatic ?? false) &&
            !(f.isConst ?? false));
        getterNames.addAll(instanceFields.map((f) => f.name!));
      }

      classRef = classResponse.superClass;
    }

    // TODO(dantup): Check this (comment comes from Dart-Code DAP).
    // Remove _identityHashCode because it seems to throw
    // (and probably isn't useful to the user).
    getterNames.remove('_identityHashCode');

    return getterNames;
  }
}
