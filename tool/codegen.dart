import 'package:collection/collection.dart';

import 'json_schema.dart';
import 'json_schema_extensions.dart';

void writeSpecClasses(IndentableStringBuffer buffer, JsonSchema schema) {
  for (final entry in schema.definitions.entries) {
    final name = entry.key;
    final type = entry.value;
    final properties = schema.propertiesFor(type);

    _writeTypeDescription(buffer, type);
    buffer
      ..writeln('class $name {')
      ..indent();
    for (final entry in properties.entries) {
      final name = entry.key;
      final isOptional = type.required?.contains(name) ?? true;
      final property = entry.value;
      final dartType = schema.dartTypeFor(property, isOptional: isOptional);
      _writeDescription(buffer, property.description);
      buffer.writeIndentedln('$dartType $name;');
    }
    buffer
      ..outdent()
      ..writeln('}')
      ..writeln();
  }
}

Iterable<String> _wrapLines(List<String> lines, int maxLength) sync* {
  lines = lines.map((l) => l.trimRight()).toList();
  for (var line in lines) {
    while (true) {
      if (line.length <= maxLength || line.startsWith('-')) {
        yield line;
        break;
      } else {
        var lastSpace = line.lastIndexOf(' ', maxLength);
        // If there was no valid place to wrap, yield the whole string.
        if (lastSpace == -1) {
          yield line;
          break;
        } else {
          yield line.substring(0, lastSpace);
          line = line.substring(lastSpace + 1);
        }
      }
    }
  }
}

void _writeDescription(IndentableStringBuffer buffer, String? description) {
  final maxLength = 80 - buffer.totalIndent - 4;
  if (description != null) {
    for (final line in _wrapLines(description.split('\n'), maxLength)) {
      buffer.writeIndentedln('/// $line');
    }
  }
}

void _writeTypeDescription(IndentableStringBuffer buffer, JsonType type) {
  // In the DAP spec, many of the descriptions are on one of the allOf types
  // rather than the type itself.
  final description = type.description ??
      type.allOf
          ?.firstWhereOrNull((element) => element.description != null)
          ?.description;

  _writeDescription(buffer, description);
}

class IndentableStringBuffer extends StringBuffer {
  int _indentLevel = 0;
  final int _indentSpaces = 2;

  int get totalIndent => _indentLevel * _indentSpaces;
  String get _indentString => ' ' * totalIndent;

  void indent() => _indentLevel++;
  void outdent() => _indentLevel--;

  void writeIndented(Object obj) {
    write(_indentString);
    write(obj);
  }

  void writeIndentedln(Object obj) {
    write(_indentString);
    writeln(obj);
  }
}
