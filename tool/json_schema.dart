import 'package:dap/src/temp_borrowed_from_analysis_server/protocol_special.dart';

class JsonSchema extends JsonType {
  final Uri dollarSchema;
  final Map<String, JsonType> definitions;

  JsonSchema.fromJson(Map<String, Object?> json)
      : dollarSchema = Uri.parse(json[r'$schema'] as String),
        definitions = (json['definitions'] as Map<String, Object?>).map((key,
                value) =>
            MapEntry(key, JsonType.fromJson(value as Map<String, Object?>))),
        super.fromJson(json);
}

class JsonType {
  final List<JsonType>? allOf;
  final String? description;
  final String? dollarRef;
  final Map<String, JsonType>? properties;
  final String? title;
  final Either2<String, List<String>>? type;

  JsonType.fromJson(Map<String, Object?> json)
      : allOf = json['allOf'] == null
            ? null
            : (json['allOf'] as List<Object?>)
                .cast<Map<String, Object?>>()
                .map((item) => JsonType.fromJson(item))
                .toList(),
        dollarRef = json[r'$ref'] as String?,
        type = json['type'] == null
            ? null
            : json['type'] is String
                ? Either2<String, List<String>>.t1(json['type'] as String)
                : Either2<String, List<String>>.t2(
                    (json['type'] as List<Object?>).cast<String>()),
        title = json['title'] as String?,
        description = json['description'] as String?,
        properties = json['properties'] == null
            ? null
            : (json['properties'] as Map<String, Object?>).map((key, value) =>
                MapEntry(
                    key, JsonType.fromJson(value as Map<String, Object?>)));
}
