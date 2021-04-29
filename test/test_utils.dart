import 'dart:isolate';

import 'package:path/path.dart' as path;

final Future<String> testApplicationsDirectory = (() async => path.join(
    path.dirname(path.dirname(
        (await Isolate.resolvePackageUri(Uri.parse('package:dap/dap.dart')))!
            .toFilePath())),
    'test/test_applications'))();
