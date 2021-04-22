import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;

import 'json_schema.dart';
import 'json_schema_extensions.dart';

Future<void> main(List<String> arguments) async {
  final args = argParser.parse(arguments);
  if (args[argHelp]) {
    print(argParser.usage);
    return;
  }

  if (args[argDownload]) {
    await downloadSpec();
  }

  final schemaContent = await File(specFile).readAsString();
  final schemaJson = jsonDecode(schemaContent);
  final schema = JsonSchema.fromJson(schemaJson);

  writeSpecClasses(schema);
}

const argDownload = 'download';

const argHelp = 'help';
final argParser = ArgParser()
  ..addFlag(argHelp, hide: true)
  ..addFlag(argDownload,
      negatable: false,
      abbr: 'd',
      help: 'Download latest version of the DAP spec before generating types');

final licenseFile = path.join(specFolder, 'debugAdapterProtocol.license.txt');

final specFile = path.join(specFolder, 'debugAdapterProtocol.json');
final specFolder = path.join(toolFolder, 'external_dap_spec');
final specLicenseUri = Uri.parse(
    'https://raw.githubusercontent.com/microsoft/debug-adapter-protocol/main/License.txt');
final specUri = Uri.parse(
    'https://raw.githubusercontent.com/microsoft/debug-adapter-protocol/gh-pages/debugAdapterProtocol.json');
final toolFolder = path.dirname(Platform.script.toFilePath());
Future<void> downloadSpec() async {
  final specResp = await http.get(specUri);
  final licenseResp = await http.get(specLicenseUri);

  assert(specResp.statusCode == 200);
  assert(licenseResp.statusCode == 200);

  final licenseHeader = '''
debugAdapterProtocol.json is an unmodified copy of the DAP Specification,
downloaded from:

  $specUri

The licence for this file is included below. This accompanying file is the
version of the specification that was used to generate a portion of the Dart
code used to support the protocol.

To regenerate the generated code, run the script in "tool/generate_all.dart"
with no arguments. To download the latest version of the specification before
regenerating the code, run the same script with the "--download" argument.

---
''';

  await File(specFile).writeAsString(specResp.body);
  await File(licenseFile).writeAsString('$licenseHeader\n${licenseResp.body}');
}

void writeSpecClasses(JsonSchema schema) {
  for (final entry in schema.definitions.entries) {
    final name = entry.key;
    final type = schema.typeFor(entry.value);
    final properties = schema.propertiesFor(type);

    print(name);
    for (final entry in properties.entries) {
      final name = entry.key;
      final isOptional = type.required?.contains(name) ?? true;
      final property = entry.value;
      final dartType = schema.dartTypeFor(property, isOptional: isOptional);
      print('  $dartType $name');
    }
  }
}
