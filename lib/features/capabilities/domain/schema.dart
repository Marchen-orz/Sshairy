import 'dart:convert';

import '../../../foundation/result.dart';

/// The deliberately small schema dialect accepted by agent tools. Unknown schema keywords fail closed.
class CapabilitySchema {
  static const maxBytes = 64 * 1024;
  static const maxDepth = 16;
  static const maxNodes = 4096;

  static Result<Map<String, Object?>> validate(Map<String, Object?> schema, Map<String, Object?> args) {
    final Map<String, Object?> frozenSchema;
    try {
      frozenSchema = _JsonBudget().copy(schema) as Map<String, Object?>;
      _checkSchema(frozenSchema);
      if (frozenSchema['type'] != 'object') throw const _InvalidSchema();
    } on _InvalidJson {
      return const Err(AppError('invalidSchema'));
    } on _InvalidSchema {
      return const Err(AppError('invalidSchema'));
    }
    try {
      final frozen = _JsonBudget().copy(args) as Map<String, Object?>;
      if (!_accepts(frozenSchema, frozen)) return const Err(AppError('invalidArgument'));
      return Ok(frozen);
    } on _InvalidJson {
      return const Err(AppError('invalidArgument'));
    }
  }

  static const _types = {'object', 'array', 'string', 'integer', 'number', 'boolean', 'null'};
  static const _common = {'type', 'enum', 'title', 'description'};
  static const _object = {'properties', 'required', 'additionalProperties', 'minProperties', 'maxProperties'};
  static const _array = {'items', 'minItems', 'maxItems', 'uniqueItems'};
  static const _string = {'minLength', 'maxLength', 'pattern'};
  static const _number = {'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum'};

  static Set<String> _schemaTypes(Map<String, Object?> schema) {
    final raw = schema['type'];
    if (raw is String && _types.contains(raw)) return {raw};
    if (raw is List && raw.isNotEmpty && raw.every((v) => v is String && _types.contains(v))) {
      final types = raw.cast<String>().toSet();
      if (types.length == raw.length) return types;
    }
    throw const _InvalidSchema();
  }

  static void _checkSchema(Map<String, Object?> schema) {
    final types = _schemaTypes(schema);
    final allowed = {
      ..._common,
      if (types.contains('object')) ..._object,
      if (types.contains('array')) ..._array,
      if (types.contains('string')) ..._string,
      if (types.contains('number') || types.contains('integer')) ..._number,
    };
    if (schema.keys.any((key) => !allowed.contains(key))) throw const _InvalidSchema();
    for (final key in ['title', 'description']) {
      if (schema.containsKey(key) && schema[key] is! String) throw const _InvalidSchema();
    }
    if (schema.containsKey('enum')) {
      final values = schema['enum'];
      if (values is! List || values.isEmpty || values.map(_canonical).toSet().length != values.length) {
        throw const _InvalidSchema();
      }
    }
    if (types.contains('object')) {
      final properties = schema.containsKey('properties') ? schema['properties'] : const <String, Object?>{};
      if (properties is! Map<String, Object?>) throw const _InvalidSchema();
      if (schema.containsKey('additionalProperties') && schema['additionalProperties'] != false) {
        throw const _InvalidSchema();
      }
      final required = schema.containsKey('required') ? schema['required'] : const <String>[];
      if (required is! List ||
          required.any((key) => key is! String || !properties.containsKey(key)) ||
          required.toSet().length != required.length) {
        throw const _InvalidSchema();
      }
      for (final child in properties.values) {
        if (child is! Map<String, Object?>) throw const _InvalidSchema();
        _checkSchema(child);
      }
      _checkRange(schema, 'minProperties', 'maxProperties');
    }
    if (types.contains('array')) {
      final items = schema['items'];
      if (items is! Map<String, Object?>) throw const _InvalidSchema();
      _checkSchema(items);
      _checkRange(schema, 'minItems', 'maxItems');
      if (schema.containsKey('uniqueItems') && schema['uniqueItems'] is! bool) throw const _InvalidSchema();
    }
    if (types.contains('string')) {
      _checkRange(schema, 'minLength', 'maxLength');
      if (schema.containsKey('pattern')) {
        final pattern = schema['pattern'];
        if (pattern is! String || pattern.length > 1024) throw const _InvalidSchema();
        try {
          RegExp(pattern, unicode: true);
        } on FormatException {
          throw const _InvalidSchema();
        }
      }
    }
    for (final key in _number) {
      if (schema.containsKey(key) && schema[key] is! num) throw const _InvalidSchema();
    }
    final minimum = schema['minimum'], maximum = schema['maximum'];
    if (minimum is num && maximum is num && minimum > maximum) throw const _InvalidSchema();
  }

  static void _checkRange(Map<String, Object?> schema, String lower, String upper) {
    for (final key in [lower, upper]) {
      final bound = schema[key];
      if (schema.containsKey(key) && (bound is! int || bound < 0)) throw const _InvalidSchema();
    }
    final min = schema[lower], max = schema[upper];
    if (min is int && max is int && min > max) throw const _InvalidSchema();
  }

  static bool _accepts(Map<String, Object?> schema, Object? value) {
    if (!_schemaTypes(schema).any((type) => _matchesType(type, value))) return false;
    final choices = schema['enum'];
    if (choices is List && !choices.any((choice) => _canonical(choice) == _canonical(value))) return false;
    if (value is Map<String, Object?>) {
      final properties = (schema['properties'] ?? const <String, Object?>{}) as Map<String, Object?>;
      final required = (schema['required'] ?? const <String>[]) as List;
      if (required.any((key) => !value.containsKey(key)) ||
          value.keys.any((key) => !properties.containsKey(key)) ||
          !_inRange(value.length, schema['minProperties'], schema['maxProperties'])) {
        return false;
      }
      for (final entry in value.entries) {
        if (!_accepts(properties[entry.key] as Map<String, Object?>, entry.value)) return false;
      }
    } else if (value is List) {
      if (!_inRange(value.length, schema['minItems'], schema['maxItems'])) return false;
      if (schema['uniqueItems'] == true && value.map(_canonical).toSet().length != value.length) return false;
      final items = schema['items'] as Map<String, Object?>;
      if (value.any((item) => !_accepts(items, item))) return false;
    } else if (value is String) {
      if (!_inRange(value.runes.length, schema['minLength'], schema['maxLength'])) return false;
      final pattern = schema['pattern'];
      if (pattern is String && !RegExp(pattern, unicode: true).hasMatch(value)) return false;
    } else if (value is num) {
      if (!_inRange(value, schema['minimum'], schema['maximum'])) return false;
      final lower = schema['exclusiveMinimum'], upper = schema['exclusiveMaximum'];
      if ((lower is num && value <= lower) || (upper is num && value >= upper)) return false;
    }
    return true;
  }

  static bool _matchesType(String type, Object? value) => switch (type) {
    'object' => value is Map<String, Object?>,
    'array' => value is List,
    'string' => value is String,
    'integer' => value is int || (value is double && value.isFinite && value == value.truncateToDouble()),
    'number' => value is num && value.isFinite,
    'boolean' => value is bool,
    'null' => value == null,
    _ => false,
  };

  static bool _inRange(num value, Object? lower, Object? upper) =>
      (lower is! num || value >= lower) && (upper is! num || value <= upper);
}

/// Copies the caller's tree before any approval can await; no custom objects, non-finite numbers or cycles survive.
class _JsonBudget {
  var _bytes = 0, _nodes = 0;

  Object? copy(Object? value, [int depth = 0]) {
    if (depth > CapabilitySchema.maxDepth || ++_nodes > CapabilitySchema.maxNodes) throw const _InvalidJson();
    if (value is String) {
      if (value.length > CapabilitySchema.maxBytes - _bytes) throw const _InvalidJson();
      _add(utf8.encode(jsonEncode(value)).length);
      return value;
    }
    if (value == null || value is bool || value is num) {
      if (value is num && !value.isFinite) throw const _InvalidJson();
      _add(jsonEncode(value).length);
      return value;
    }
    if (value is List) {
      _add(2 + value.length);
      return List<Object?>.unmodifiable([for (final item in value) copy(item, depth + 1)]);
    }
    if (value is Map) {
      _add(2 + value.length * 2);
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        if (entry.key is! String) throw const _InvalidJson();
        final key = copy(entry.key, depth + 1) as String;
        result[key] = copy(entry.value, depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    throw const _InvalidJson();
  }

  void _add(int count) {
    _bytes += count;
    if (_bytes > CapabilitySchema.maxBytes) throw const _InvalidJson();
  }
}

String _canonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonical(value[key])}').join(',')}}';
  }
  if (value is List) return '[${value.map(_canonical).join(',')}]';
  // JSON Schema treats numerically equal values as equal, including integer-valued doubles.
  if (value is double && value == value.truncateToDouble()) return BigInt.from(value).toString();
  return jsonEncode(value);
}

class _InvalidSchema implements Exception {
  const _InvalidSchema();
}

class _InvalidJson implements Exception {
  const _InvalidJson();
}
