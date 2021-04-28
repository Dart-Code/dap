import 'dart:math';

import 'package:collection/collection.dart';

import 'json_schema.dart';
import 'json_schema_extensions.dart';

class CodeGenerator {
  void writeSpecClasses(IndentableStringBuffer buffer, JsonSchema schema) {
    for (final entry in schema.definitions.entries.sortedBy((e) => e.key)) {
      final name = entry.key;
      final type = entry.value;
      final baseType = type.baseType;
      final resolvedBaseType =
          baseType != null ? schema.typeFor(baseType) : null;
      final classProperties = schema.propertiesFor(type, includeBase: false);
      final baseProperties = resolvedBaseType != null
          ? schema.propertiesFor(resolvedBaseType)
          : <String, JsonType>{};

      _writeTypeDescription(buffer, type);
      buffer.write('class $name ');
      if (baseType != null) {
        buffer.write('extends ${baseType.refName} ');
      }
      buffer
        ..writeln('{')
        ..indent();
      _writeFields(buffer, type, classProperties);
      buffer.writeln();
      _writeFromJsonStaticMethod(buffer, name);
      buffer.writeln();
      _writeConstructor(buffer, name, type, classProperties, baseProperties,
          baseType: resolvedBaseType);
      buffer.writeln();
      _writeFromMapConstructor(buffer, name, type, classProperties,
          callSuper: resolvedBaseType != null);
      buffer.writeln();
      _writeCanParseMethod(buffer, type, classProperties,
          baseTypeRefName: baseType?.refName);
      buffer
        ..outdent()
        ..writeln('}')
        ..writeln();
    }
  }

  String _dartSafeName(String name) {
    const improvedName = {
      'default': 'defaultValue',
    };
    return improvedName[name] ??
        // Some types are prefixed with _ in the spec but that will make them
        // private in Dart and inaccessible to the adapter so we strip it off.
        name
            .replaceAll(RegExp(r'^_+'), '')
            // Also replace any other scores to make camelCase
            .replaceAllMapped(
                RegExp(r'_(.)'), (m) => m.group(1)!.toUpperCase());
  }

  Iterable<String> _wrapLines(List<String> lines, int maxLength) sync* {
    lines = lines.map((l) => l.trimRight()).toList();
    for (var line in lines) {
      while (true) {
        if (line.length <= maxLength || line.startsWith('-')) {
          yield line;
          break;
        } else {
          var lastSpace = line.lastIndexOf(' ', max(maxLength, 0));
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

  void _writeCanParseMethod(
    IndentableStringBuffer buffer,
    JsonType type,
    Map<String, JsonType> properties, {
    required String? baseTypeRefName,
  }) {
    buffer
      ..writeIndentedln('static bool canParse(Object? obj) {')
      ..indent()
      ..writeIndentedln('if (obj is! Map<String, dynamic>) {')
      ..indent()
      ..writeIndentedln('return false;')
      ..outdent()
      ..writeIndentedln('}');
    // In order to consider this valid for parsing, all fields that must not be
    // undefined must be present and also type check for the correct type.
    // Any fields that are optional but present, must still type check.
    for (final entry in properties.entries.sortedBy((e) => e.key)) {
      final propertyName = entry.key;
      final propertyType = entry.value;
      final isOptional = !type.requiresField(propertyName);

      if (propertyType.isAny && isOptional) {
        continue;
      }

      if (!isOptional) {
        buffer
          ..writeIndentedln("if (!obj.containsKey('$propertyName')) {")
          ..indent()
          ..writeIndentedln('return false;')
          ..outdent()
          ..writeIndentedln('}');
      }
      buffer.writeIndented('if (');
      _writeTypeCheckCondition(buffer, propertyType, "obj['$propertyName']",
          isOptional: isOptional, invert: true);
      buffer
        ..writeln(') {')
        ..indent()
        ..writeIndentedln('return false;')
        ..outdent()
        ..writeIndentedln('}');
    }
    buffer
      ..writeIndentedln(
        baseTypeRefName != null
            ? 'return $baseTypeRefName.canParse(obj);'
            : 'return true;',
      )
      ..outdent()
      ..writeIndentedln('}');
  }

  void _writeDescription(IndentableStringBuffer buffer, String? description) {
    final maxLength = 80 - buffer.totalIndent - 4;
    if (description != null) {
      for (final line in _wrapLines(description.split('\n'), maxLength)) {
        buffer.writeIndentedln('/// $line');
      }
    }
  }

  void _writeFields(IndentableStringBuffer buffer, JsonType type,
      Map<String, JsonType> properties) {
    for (final entry in properties.entries.sortedBy((e) => e.key)) {
      final propertyName = entry.key;
      final fieldName = _dartSafeName(propertyName);
      final propertyType = entry.value;
      final isOptional = !type.requiresField(propertyName);
      final dartType = propertyType.asDartType(isOptional: isOptional);
      _writeDescription(buffer, propertyType.description);
      buffer.writeIndentedln('final $dartType $fieldName;');
    }
  }

  void _writeFromJsonExpression(
      IndentableStringBuffer buffer, JsonType type, String valueCode,
      {bool isOptional = false}) {
    final dartType = type.asDartType(isOptional: isOptional);
    final dartTypeNotNullable = type.asDartType();
    final nullOp = isOptional ? '?' : '';

    if (type.isAny || type.isSimple) {
      buffer.write('$valueCode');
      if (dartType != 'Object?') {
        buffer.write(' as $dartType');
      }
    } else if (type.isList) {
      buffer.write('($valueCode as List$nullOp)$nullOp.map((item) => ');
      _writeFromJsonExpression(buffer, type.items!, 'item');
      buffer.write(').toList()');
    } else if (type.isUnion) {
      final types = type.unionTypes;

      // Write a check against each type, eg.:
      // x is y ? new Either.tx(x) : (...)
      for (var i = 0; i < types.length; i++) {
        final isLast = i == types.length - 1;

        // For the last item, we won't wrap if in a check, as the constructor
        // will only be called if canParse() returned true, so it's the only
        // remaining option.
        if (!isLast) {
          _writeTypeCheckCondition(buffer, types[i], valueCode,
              isOptional: false);
          buffer.write(' ? ');
        }
        buffer.write('$dartTypeNotNullable.t${i + 1}(');
        _writeFromJsonExpression(buffer, types[i], valueCode);
        buffer.write(')');

        if (!isLast) {
          buffer.write(' : ');
        }
      }
    } else if (type.isSpecType) {
      buffer.write(
          '$dartTypeNotNullable.fromJson($valueCode as Map<String, Object?>)');
    } else {
      throw 'Unable to type check $valueCode against $type';
    }
  }

  void _writeFromJsonStaticMethod(
    IndentableStringBuffer buffer,
    String name,
  ) =>
      buffer.writeIndentedln(
          'static $name fromJson(Map<String, Object?> obj) => $name.fromMap(obj);');

  void _writeConstructor(
    IndentableStringBuffer buffer,
    String name,
    JsonType type,
    Map<String, JsonType> classProperties,
    Map<String, JsonType> baseProperties, {
    required JsonType? baseType,
  }) {
    buffer.writeIndented('$name(');
    if (classProperties.isNotEmpty || baseProperties.isNotEmpty) {
      buffer
        ..writeln('{')
        ..indent();
      for (final entry in classProperties.entries.sortedBy((e) => e.key)) {
        final propertyName = entry.key;
        final fieldName = _dartSafeName(propertyName);
        final isOptional = !type.requiresField(propertyName);
        buffer.writeIndented('');
        if (!isOptional) {
          buffer.write('required ');
        }
        buffer.writeln('this.$fieldName, ');
      }
      for (final entry in baseProperties.entries.sortedBy((e) => e.key)) {
        final propertyName = entry.key;
        final fieldName = _dartSafeName(propertyName);
        final propertyType = entry.value;
        final isOptional = !type.requiresField(propertyName);
        final dartType = propertyType.asDartType(isOptional: isOptional);
        buffer.writeIndented('');
        if (!isOptional) {
          buffer.write('required ');
        }
        buffer.writeln('$dartType $fieldName, ');
      }
      buffer
        ..outdent()
        ..writeIndented('}');
    }
    buffer.write(')');

    if (baseType != null) {
      buffer.write(': super(');
      if (baseProperties.isNotEmpty) {
        buffer
          ..writeln()
          ..indent();
        for (final propertyName in baseProperties.keys) {
          final fieldName = _dartSafeName(propertyName);
          buffer.writeIndentedln('$fieldName: $fieldName, ');
        }
        buffer
          ..outdent()
          ..writeIndented('');
      }
      buffer.write(')');
    }
    buffer.writeln(';');
  }

  void _writeFromMapConstructor(
    IndentableStringBuffer buffer,
    String name,
    JsonType type,
    Map<String, JsonType> properties, {
    bool callSuper = false,
  }) {
    buffer.writeIndented('$name.fromMap(Map<String, Object?> obj)');
    if (properties.isNotEmpty || callSuper) {
      buffer
        ..writeln(':')
        ..indent();
      var isFirst = true;
      for (final entry in properties.entries.sortedBy((e) => e.key)) {
        if (isFirst) {
          isFirst = false;
        } else {
          buffer.writeln(',');
        }

        final propertyName = entry.key;
        final fieldName = _dartSafeName(propertyName);
        final propertyType = entry.value;
        final isOptional = !type.requiresField(propertyName);

        buffer.writeIndented('$fieldName = ');
        _writeFromJsonExpression(buffer, propertyType, "obj['$propertyName']",
            isOptional: isOptional);
      }
      if (callSuper) {
        if (!isFirst) {
          buffer.writeln(',');
        }
        buffer.writeIndented('super.fromMap(obj)');
      }
      buffer.outdent();
    }
    buffer.writeln(';');
  }

  void _writeTypeCheckCondition(
      IndentableStringBuffer buffer, JsonType type, String valueCode,
      {required bool isOptional, bool invert = false}) {
    final dartType = type.asDartType(isOptional: isOptional);

    // Invert operators when inverting the checks, this will produce cleaner code.
    final opBang = invert ? '!' : '';
    final opTrue = invert ? 'false' : 'true';
    final opIs = invert ? 'is!' : 'is';
    final opAnd = invert ? '||' : '&&';
    final opOr = invert ? '&&' : '||';
    final opEvery = invert ? 'any' : 'every';

    if (type.isAny) {
      buffer.write(opTrue);
    } else if (type.isSimple) {
      buffer.write('$valueCode $opIs $dartType');
    } else if (type.isList) {
      buffer.write('($valueCode $opIs List');
      buffer.write(' $opAnd ($valueCode.$opEvery((item) => ');
      _writeTypeCheckCondition(buffer, type.items!, 'item',
          isOptional: false, invert: invert);
      buffer.write('))');
      buffer.write(')');
    } else if (type.isUnion) {
      final types = type.unionTypes;
      // To type check a union, we just recursively check against each of its types.
      buffer.write('(');
      for (var i = 0; i < types.length; i++) {
        if (i != 0) {
          buffer.write(' $opOr ');
        }
        _writeTypeCheckCondition(buffer, types[i], valueCode,
            isOptional: false, invert: invert);
      }
      buffer.write(')');
    } else if (type.isSpecType) {
      buffer.write('$opBang$dartType.canParse($valueCode)');
    } else {
      throw 'Unable to type check $valueCode against $type';
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