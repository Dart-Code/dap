import 'json_schema.dart';
import 'package:collection/collection.dart';

const _dartSimpleTypes = {
  'bool',
  'int',
  'num',
  'String',
  'Map<String, Object?>',
  'Null',
};

String _toDartType(String type) {
  if (type.startsWith('#/definitions/')) {
    return type.replaceAll('#/definitions/', '');
  }
  switch (type) {
    case 'object':
      return 'Map<String, Object?>';
    case 'integer':
      return 'int';
    case 'number':
      return 'num';
    case 'string':
      return 'String';
    case 'boolean':
      return 'bool';
    case 'null':
      return 'Null';
    default:
      return type;
  }
}

String _toDartUnionType(List<String> types) {
  const allLiteralTypes = {
    'array',
    'boolean',
    'integer',
    'null',
    'number',
    'object',
    'string'
  };
  if (types.length == 7 && allLiteralTypes.containsAll(types)) {
    return 'Object';
  }
  return 'Either${types.length}<${types.map(_toDartType).join(', ')}>';
}

extension JsonSchemaExtensions on JsonSchema {
  JsonType typeFor(JsonType type) => type.dollarRef != null
      // TODO(dantup): Do we need to support more than just refs to definitions?
      ? definitions[type.refName]!
      : type;

  Map<String, JsonType> propertiesFor(JsonType type,
      {bool includeBase = true}) {
    // Merge this types direct properties with anything from the included
    // (allOf) types, but excluding those that come from the base class.
    final baseType = type.baseType;
    final includedBaseTypes =
        (type.allOf ?? []).where((t) => includeBase || t != baseType);
    final properties = {
      for (final other in includedBaseTypes) ...propertiesFor(typeFor(other)),
      ...?type.properties,
    };

    return properties;
  }
}

extension JsonTypeExtensions on JsonType {
  String asDartType({bool isOptional = false}) {
    final dartType = dollarRef != null
        ? _toDartType(dollarRef!)
        : oneOf != null
            ? _toDartUnionType(oneOf!.map((item) => item.asDartType()).toList())
            : type!.valueEquals('array')
                ? 'List<${items!.asDartType()}>'
                : type!.map(_toDartType, _toDartUnionType);

    return isOptional ? '$dartType?' : dartType;
  }

  bool get isAny => asDartType() == 'Object';
  bool get isList => type?.valueEquals('array') ?? false;
  bool get isSimple => _dartSimpleTypes.contains(asDartType());
  bool get isUnion =>
      oneOf != null || type != null && type!.map((_) => false, (_) => true);
  bool get isSpecType => dollarRef != null;

  bool requiresField(String propertyName) {
    if (required?.contains(propertyName) ?? false) {
      return true;
    }
    if (allOf?.any((type) => root.typeFor(type).requiresField(propertyName)) ??
        false) {
      return true;
    }

    return false;
  }

  String get refName => dollarRef!.replaceAll('#/definitions/', '');

  String? get literalValue => enumValues?.singleOrNull;

  JsonType? get baseType {
    final all = allOf;
    if (all != null && all.length > 1 && all.first.dollarRef != null) {
      return all.first;
    }
    return null;
  }

  List<JsonType> get unionTypes {
    final types = oneOf ??
        // Fabricate a union for types where "type" is an array of literal types:
        // ['a', 'b']
        type!.map(
          (_) => throw 'unexpected non-union in isUnion condition',
          (types) =>
              types.map((t) => JsonType.fromJson(root, {'type': t})).toList(),
        )!;
    return types;
  }
}
