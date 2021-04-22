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
      ? definitions[type.dollarRef!.replaceAll('#/definitions/', '')]!
      : type;

  Map<String, JsonType> propertiesFor(JsonType type) => {
        for (final other in type.allOf ?? []) ...propertiesFor(typeFor(other)),
        ...?type.properties,
      };
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
}
