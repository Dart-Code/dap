// TODO(dantup): This file should be generated from the DAP spec.

Object? specToJson(Object? obj) {
  if (obj is ToJsonable) {
    return obj.toJson();
  } else {
    return obj;
  }
}

class Capabilities extends ToJsonable {
  final bool? supportsConfigurationDoneRequest;

  Capabilities({this.supportsConfigurationDoneRequest});

  @override
  Map<String, Object?> toJson() => {
        'supportsConfigurationDoneRequest': supportsConfigurationDoneRequest,
      };

  static Capabilities fromJson(Map<String, Object?> json) => Capabilities(
        supportsConfigurationDoneRequest:
            json['supportsConfigurationDoneRequest'] as bool?,
      );
}

// class ErrorResponse extends Response<ErrorResponseBody> {
//   ErrorResponse(int sequence, int requestSequence, String command,
//       String? message, ErrorResponseBody body)
//       : super.failure(sequence, requestSequence, command, message, body);
// }

// class ErrorResponseBody {
//   Message? error;
// }

class ConfigurationDoneArgs implements ToJsonable {
  ConfigurationDoneArgs();

  @override
  Map<String, Object?> toJson() => {};

  static ConfigurationDoneArgs fromJson(Map<String, Object?> json) =>
      ConfigurationDoneArgs();
}

class DisconnectArgs implements ToJsonable {
  final bool? restart;
  final bool? terminateDebuggee;

  DisconnectArgs({this.restart, this.terminateDebuggee});

  @override
  Map<String, Object?> toJson() => {
        'restart': restart,
        'terminateDebuggee': terminateDebuggee,
      };

  static DisconnectArgs fromJson(Map<String, Object?> json) => DisconnectArgs(
        restart: json['restart'] as bool?,
        terminateDebuggee: json['terminateDebuggee'] as bool?,
      );
}

class Event extends ProtocolMessage {
  final Object? body;
  final String event;

  Event(int sequence, this.event, this.body) : super(sequence);

  @override
  String get type => 'event';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'seq': sequence,
        'event': event,
        'body': specToJson(body),
      };

  static Event fromJson(Map<String, Object?> json) => Event(
        json['seq'] as int,
        json['event'] as String,
        json['body'],
      );
}

abstract class EventBody implements ToJsonable {
  String get event;
}

class InitializeArgs implements ToJsonable {
  InitializeArgs();

  @override
  Map<String, Object?> toJson() => {};

  static InitializeArgs fromJson(Map<String, Object?> json) => InitializeArgs();
}

class InitializedEventBody extends EventBody {
  @override
  String get event => 'initialized';

  @override
  Map<String, Object?> toJson() => {};
}

abstract class InitializeResponse {
  static Capabilities fromBody(Object? body) =>
      Capabilities.fromJson(body as Map<String, Object?>);
}

class LaunchArgs implements ToJsonable {
  final bool? noDebug;
  final Object? restart;
  final String program;
  final String? cwd;
  final List<String>? args;
  final String dartSdkPath;

  LaunchArgs({
    this.noDebug,
    this.restart,
    required this.program,
    this.cwd,
    this.args,
    required this.dartSdkPath,
  });

  @override
  Map<String, Object?> toJson() => {
        'noDebug': noDebug,
        '__restart': restart,
        'program': program,
        'cwd': cwd,
        'args': args,
        'dartSdkPath': dartSdkPath,
      };

  static LaunchArgs fromJson(Map<String, Object?> json) => LaunchArgs(
        noDebug: json['noDebug'] as bool?,
        restart: json['__restart'],
        program: json['program'] as String,
        cwd: json['cwd'] as String?,
        args:
            json['args'] != null ? (json['args'] as List).cast<String>() : null,
        dartSdkPath: json['dartSdkPath'] as String,
      );
}

class Message {
  final int id;
  final String format;
  final Map<String, String>? variables;
  final bool? sendTelemetry;
  final bool? showUser;
  final String? url;
  final String? urlLabel;

  Message(this.id, this.format, this.variables, this.sendTelemetry,
      this.showUser, this.url, this.urlLabel);
}

class OutputEventBody extends EventBody {
  final String? category;
  final String output;
  final int? variablesReference;
  // TODO(dantup): Add source class
  // final Source? source;
  final int? line;
  final int? column;
  final Object? data;

  OutputEventBody({
    this.category,
    required this.output,
    this.variablesReference,
    this.line,
    this.column,
    this.data,
  });

  @override
  String get event => 'output';

  @override
  Map<String, Object?> toJson() => {
        'category': category,
        'output': output,
        'variablesReference': variablesReference,
        // 'source': source,
        'line': line,
        'column': column,
        'data': data,
      };

  static OutputEventBody fromJson(Map<String, Object?> json) => OutputEventBody(
        category: json['category'] as String?,
        output: json['output'] as String,
        variablesReference: json['variablesReference'] as int?,
        // source: json['source'] != null ? Source.fromJson(json['source']) : null,
        line: json['line'] as int?,
        column: json['column'] as int?,
        data: json['data'],
      );
}

abstract class ProtocolMessage implements ToJsonable {
  final int sequence;

  ProtocolMessage(this.sequence);
  String get type;
}

class Request extends ProtocolMessage {
  final Object? arguments;
  final String command;

  Request(int sequence, this.command, this.arguments) : super(sequence);

  @override
  String get type => 'request';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'seq': sequence,
        'command': command,
        'arguments': specToJson(arguments),
      };

  static Request fromJson(Map<String, Object?> json) => Request(
        json['seq'] as int,
        json['command'] as String,
        json['arguments'],
      );
}

class Response extends ProtocolMessage {
  final int requestSequence;
  final bool success;
  final String command;
  final String? message;
  final Object? body;

  Response.failure(
      int sequence, this.requestSequence, this.command, this.message, this.body)
      : success = false,
        super(sequence);

  Response.success(int sequence, this.requestSequence, this.command, this.body)
      : success = true,
        message = null,
        super(sequence);

  @override
  String get type => 'response';

  @override
  Map<String, Object?> toJson() => {
        'type': type,
        'seq': sequence,
        'request_seq': requestSequence,
        'success': success,
        'command': command,
        'message': message,
        'body': specToJson(body)
      };

  static Response fromJson(Map<String, Object?> json) => json['success'] as bool
      ? Response.success(
          json['seq'] as int,
          json['request_seq'] as int,
          json['command'] as String,
          json['body'],
        )
      : Response.failure(
          json['seq'] as int,
          json['request_seq'] as int,
          json['command'] as String,
          json['message'] as String?,
          json['body'],
        );
}

class TerminatedEventBody extends EventBody {
  final Object? restart;

  TerminatedEventBody({
    this.restart,
  });

  @override
  String get event => 'terminated';

  @override
  Map<String, Object?> toJson() => {
        'restart': restart,
      };

  static TerminatedEventBody fromJson(Map<String, Object?> json) =>
      TerminatedEventBody(
        restart: json['restart'],
      );
}

abstract class ToJsonable {
  Object toJson();
}
