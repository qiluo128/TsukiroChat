/// 轻量 JSON Schema 子集校验器。
///
/// 只支持原语参数真正需要的那部分：
///   `type` / `properties` / `required` / `enum` / `additionalProperties` /
///   `items` / `minimum` / `maximum` / `minLength` / `maxLength`
///
/// 为什么不引入完整 JSON Schema 库：宿主需要在**每次原语调用**上跑校验（热路径），
/// 且要给出面向插件作者的中文错误信息。一个 200 行的子集实现比一个完整库更可控。
///
/// **fail-closed**：无法识别的关键字一律忽略（不报错也不放行判断），
/// 但未知 `type` 值会让校验失败 —— 宁可拒绝，不可放行。
library;

/// 一条校验问题。
class SchemaIssue {
  const SchemaIssue(this.path, this.message);

  /// 参数路径，如 `properties.tz.type`。
  final String path;
  final String message;

  @override
  String toString() => '$path: $message';
}

/// 校验 [value] 是否符合 [schema]。
///
/// 返回空列表表示通过。
List<SchemaIssue> validateAgainstSchema(Object? value, Map<String, dynamic> schema) {
  final issues = <SchemaIssue>[];
  _validate(value, schema, '', issues);
  return issues;
}

void _validate(
  Object? value,
  Map<String, dynamic> schema,
  String path,
  List<SchemaIssue> issues,
) {
  final where = path.isEmpty ? '<args>' : path;

  // ── enum ──
  final enumValues = schema['enum'];
  if (enumValues is List && !enumValues.contains(value)) {
    issues.add(SchemaIssue(
      where,
      '取值必须是 ${enumValues.map((e) => '"$e"').join(" / ")} 之一，收到 "$value"',
    ));
    return;
  }

  // ── type ──
  final type = schema['type'];
  if (type is String && !_matchesType(value, type)) {
    // null 单独给一句更清楚的提示：很多"参数不对"其实是插件忘了传
    if (value == null) {
      issues.add(SchemaIssue(where, '缺少必填参数（期望 $type）'));
    } else {
      issues.add(SchemaIssue(where, '类型必须是 $type，收到 ${value.runtimeType}'));
    }
    return;
  }

  // ── 数值范围 ──
  if (value is num) {
    final min = schema['minimum'];
    final max = schema['maximum'];
    if (min is num && value < min) {
      issues.add(SchemaIssue(where, '不能小于 $min，收到 $value'));
    }
    if (max is num && value > max) {
      issues.add(SchemaIssue(where, '不能大于 $max，收到 $value'));
    }
  }

  // ── 字符串长度 ──
  if (value is String) {
    final minLen = schema['minLength'];
    final maxLen = schema['maxLength'];
    if (minLen is int && value.length < minLen) {
      issues.add(SchemaIssue(where, '长度不能小于 $minLen，当前 ${value.length}'));
    }
    if (maxLen is int && value.length > maxLen) {
      issues.add(SchemaIssue(where, '长度不能超过 $maxLen，当前 ${value.length}'));
    }
  }

  // ── 对象属性 ──
  if (value is Map) {
    final properties = schema['properties'];
    final propMap = properties is Map ? properties : const <String, dynamic>{};

    final required = schema['required'];
    if (required is List) {
      for (final key in required) {
        final k = '$key';
        if (!value.containsKey(k) || value[k] == null) {
          issues.add(SchemaIssue(
            path.isEmpty ? k : '$path.$k',
            '缺少必填参数',
          ));
        }
      }
    }

    if (schema['additionalProperties'] == false) {
      for (final key in value.keys) {
        if (!propMap.containsKey('$key')) {
          issues.add(SchemaIssue(
            path.isEmpty ? '$key' : '$path.$key',
            '不认识的参数。可用参数：'
            '${propMap.isEmpty ? "（无）" : propMap.keys.join(" / ")}',
          ));
        }
      }
    }

    propMap.forEach((key, subSchema) {
      if (!value.containsKey(key)) return;
      final child = value[key];
      if (child == null) return;
      if (subSchema is Map<String, dynamic>) {
        _validate(child, subSchema, path.isEmpty ? '$key' : '$path.$key', issues);
      }
    });
  }

  // ── 数组元素 ──
  if (value is List) {
    final items = schema['items'];
    if (items is Map<String, dynamic>) {
      for (var i = 0; i < value.length; i++) {
        _validate(value[i], items, '$path[$i]', issues);
      }
    }
  }
}

bool _matchesType(Object? value, String type) {
  switch (type) {
    case 'string':
      return value is String;
    case 'number':
      return value is num;
    case 'integer':
      return value is int;
    case 'boolean':
      return value is bool;
    case 'object':
      return value is Map;
    case 'array':
      return value is List;
    case 'null':
      return value == null;
    default:
      // 未知 type → fail-closed
      return false;
  }
}
