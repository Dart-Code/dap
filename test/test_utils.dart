import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as path;

final eol = Platform.isWindows ? '\r\n' : '\n';

final Future<String> logsDirectory = (() async => path.join(
    path.dirname(path.dirname(
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath())),
    'logs'))();

final Future<String> testApplicationsDirectory = (() async => path.join(
    path.dirname(path.dirname(
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath())),
    'test/test_applications'))();

int lineWith(File file, String searchText) =>
    file.readAsLinesSync().indexWhere((line) => line.contains(searchText));
