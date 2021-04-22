import 'json_schema.dart';

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
    return 'Object?';
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

  String dartTypeFor(JsonType type, {bool isOptional = false}) {
    final dollarRef = type.dollarRef;
    final oneOf = type.oneOf;

    final dartType = dollarRef != null
        ? _toDartType(dollarRef)
        : oneOf != null
            ? _toDartUnionType(oneOf.map(dartTypeFor).toList())
            : type.type!.valueEquals('array')
                ? 'List<${dartTypeFor(type.items!)}>'
                : type.type!.map(_toDartType, _toDartUnionType);

    return isOptional ? '$dartType?' : dartType;
  }
}
