abstract class EventBody {
  static bool canParse(Object? obj) => obj is Map<String, Object?>?;
}

abstract class ResponseBody {
  static bool canParse(Object? obj) => obj is Map<String, Object?>?;
}

abstract class RequestArguments {
  static bool canParse(Object? obj) => obj is Map<String, Object?>?;
}
