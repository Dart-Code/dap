// Copyright (c) 2018, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/// Returns if two objects are equal, recursively checking items in
/// Maps/Lists.
bool dapEquals(dynamic obj1, dynamic obj2) {
  if (obj1 is List && obj2 is List) {
    return listEqual(obj1, obj2, dapEquals);
  } else if (obj1 is Map && obj2 is Map) {
    return mapEqual(obj1, obj2, dapEquals);
  } else {
    return obj1.runtimeType == obj2.runtimeType && obj1 == obj2;
  }
}

/// Returns an objects hash code, recursively combining hashes for items in
/// Maps/Lists.
int dapHashCode(dynamic obj) {
  var hash = 0;
  if (obj is List) {
    for (var element in obj) {
      hash = JenkinsSmiHash.combine(hash, dapHashCode(element));
    }
  } else if (obj is Map) {
    for (var key in obj.keys) {
      hash = JenkinsSmiHash.combine(hash, dapHashCode(key));
      hash = JenkinsSmiHash.combine(hash, dapHashCode(obj[key]));
    }
  } else {
    hash = obj.hashCode;
  }
  return JenkinsSmiHash.finish(hash);
}

/// Compare the lists [listA] and [listB], using [itemEqual] to compare
/// list elements.
bool listEqual<T>(
    List<T>? listA, List<T>? listB, bool Function(T a, T b) itemEqual) {
  if (listA == null) {
    return listB == null;
  }
  if (listB == null) {
    return false;
  }
  if (listA.length != listB.length) {
    return false;
  }
  for (var i = 0; i < listA.length; i++) {
    if (!itemEqual(listA[i], listB[i])) {
      return false;
    }
  }
  return true;
}

/// Compare the maps [mapA] and [mapB], using [valueEqual] to compare map
/// values.
bool mapEqual<K, V>(
    Map<K, V>? mapA, Map<K, V>? mapB, bool Function(V a, V b) valueEqual) {
  if (mapA == null) {
    return mapB == null;
  }
  if (mapB == null) {
    return false;
  }
  if (mapA.length != mapB.length) {
    return false;
  }
  for (var entryA in mapA.entries) {
    var key = entryA.key;
    var valueA = entryA.value;
    var valueB = mapB[key];
    if (valueB == null || !valueEqual(valueA, valueB)) {
      return false;
    }
  }
  return true;
}

Object? specToJson(Object? obj) {
  if (obj is ToJsonable) {
    return obj.toJson();
  } else {
    return obj;
  }
}

class Either2<T1, T2> {
  final int _which;
  final T1? _t1;
  final T2? _t2;

  Either2.t1(T1 this._t1)
      : _t2 = null,
        _which = 1;
  Either2.t2(T2 this._t2)
      : _t1 = null,
        _which = 2;

  @override
  int get hashCode => map(dapHashCode, dapHashCode);

  @override
  bool operator ==(o) =>
      o is Either2<T1, T2> && dapEquals(o._t1, _t1) && dapEquals(o._t2, _t2);

  T map<T>(T Function(T1) f1, T Function(T2) f2) {
    return _which == 1 ? f1(_t1 as T1) : f2(_t2 as T2);
  }

  Object? toJson() => map(specToJson, specToJson);

  @override
  String toString() => map((t) => t.toString(), (t) => t.toString());

  /// Checks whether the value of the union equals the supplied value.
  bool valueEquals(o) => map((t) => t == o, (t) => t == o);
}

/// Jenkins hash function, optimized for small integers.
///
/// Static methods borrowed from sdk/lib/math/jenkins_smi_hash.dart.  Non-static
/// methods are an enhancement for the "front_end" package.
///
/// Where performance is critical, use [hash2], [hash3], or [hash4], or the
/// pattern `finish(combine(combine(...combine(0, a), b)..., z))`, where a..z
/// are hash codes to be combined.
///
/// For ease of use, you may also use this pattern:
/// `(new JenkinsSmiHash()..add(a)..add(b)....add(z)).hashCode`, where a..z are
/// the sub-objects whose hashes should be combined.  This pattern performs the
/// same operations as the performance critical variant, but allocates an extra
/// object.
class JenkinsSmiHash {
  int _hash = 0;

  /// Finalizes the hash and return the resulting hashcode.
  @override
  int get hashCode => finish(_hash);

  /// Accumulates the object [o] into the hash.
  void add(Object o) {
    _hash = combine(_hash, o.hashCode);
  }

  /// Accumulates the hash code [value] into the running hash [hash].
  static int combine(int hash, int value) {
    hash = 0x1fffffff & (hash + value);
    hash = 0x1fffffff & (hash + ((0x0007ffff & hash) << 10));
    return hash ^ (hash >> 6);
  }

  /// Finalizes a running hash produced by [combine].
  static int finish(int hash) {
    hash = 0x1fffffff & (hash + ((0x03ffffff & hash) << 3));
    hash = hash ^ (hash >> 11);
    return 0x1fffffff & (hash + ((0x00003fff & hash) << 15));
  }

  /// Combines together two hash codes.
  static int hash2(int a, int b) => finish(combine(combine(0, a), b));

  /// Combines together three hash codes.
  static int hash3(int a, int b, int c) =>
      finish(combine(combine(combine(0, a), b), c));

  /// Combines together four hash codes.
  static int hash4(int a, int b, int c, int d) =>
      finish(combine(combine(combine(combine(0, a), b), c), d));
}

abstract class ToJsonable {
  Object toJson();
}
