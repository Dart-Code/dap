import 'json_schema.dart';

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
