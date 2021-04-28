import 'json_schema.dart';

const _dartSimpleTypes = {'bool', 'int', 'String', 'Map<String, Object?>'};

String _toDartType(String type) {
  if (type.startsWith('#/definitions/')) {
    return type.replaceAll('#/definitions/', '');
  }
  switch (type) {
    case 'object':
      return 'Map<String, Object?>';
    case 'integer':
      return 'int';
    case 'string':
      return 'String';
    case 'boolean':
      return 'bool';
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

  Map<String, JsonType> propertiesFor(JsonType type) {
    // Merge this types direct properties with anything from the included
    // (allOf) types, but excluding those that come from the base class.
    final properties = {
      ...?type.properties,
      for (final other in type.allOf ?? []) ...propertiesFor(typeFor(other))
    };

    // Remove any types that are defined in the base.
    final baseType = type.baseType;
    final basePropertyNames = baseType != null
        ? propertiesFor(typeFor(baseType)).keys.toSet()
        : <String>{};
    properties.removeWhere((name, type) => basePropertyNames.contains(name));

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

  bool requiresField(String propertyName) =>
      required?.contains(propertyName) ?? false;

  String get refName => dollarRef!.replaceAll('#/definitions/', '');

  JsonType? get baseType {
    final all = allOf;
    if (all != null && all.length > 1 && all.first.dollarRef != null) {
      return all.first;
    }
    return null;
  }
}
