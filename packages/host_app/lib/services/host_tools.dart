/// 宿主自己的工具 —— 目前是文件操作。
///
/// ## 为什么这些不是插件原语
///
/// 见 `docs/24-agent-tools.md` §5。一句话：
///
/// ```
/// 用户信任的是        宿主工具 → 这个应用
/// 插件原语 → 每一个装的插件
/// ```
///
/// 文件工具如果进原语目录，"装一个插件"就等于"可能给它用户的文件"。
///
/// ## 工作区是每智能体一个
///
/// 所以 `execute` 必须带 `agentId` —— 工具定义是全局的（只注册一次），
/// 但**作用域是每一轮对话的**。所以这里不用实例状态，而是每次调用
/// 把 agentId 传进来，避免"上一个会话的文件操作落到下一个会话"。
library;

import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';

import 'workspace_store.dart';

class HostTools {
  const HostTools._();

  /// 工具名 → handler 名。目前一一对应。
  static const List<String> names = <String>[
    'list_files',
    'read_file',
    'write_file',
    'create_folder',
  ];

  /// 宿主声明并持有的权限。
  ///
  /// `write_file` 要 `fs.write`，其余只要 `fs.read`。
  /// **列出来是为了让审计说得清"它凭什么能做这个"** ——
  /// 不是"宿主免检"。
  static const Set<String> permissions = <String>{'fs.read', 'fs.write'};

  /// 把这几个工具注册进工具表。**幂等** —— provider 重建时会再调。
  static void install({
    required ToolRegistry registry,
    required Gatekeeper gatekeeper,
  }) {
    gatekeeper.registerHost(permissions);

    for (final spec in _specs) {
      // 已经装过就跳过。registerHostTool 重名会抛，
      // 所以幂等必须在这里保证，而不是指望注册表宽容。
      if (registry.lookup(spec.name) != null) continue;

      registry.registerHostTool(RegisteredTool(
        name: spec.name,
        originalName: spec.name,
        description: spec.description,
        parameters: spec.parameters,
        pluginId: hostPluginId,
        pluginVersion: '1',
        handler: spec.name,
        permissions: spec.permissions,
        timeoutMs: 20000,
        dangerous: false,
        exposed: true,
      ));
    }
  }

  static const List<_ToolSpec> _specs = <_ToolSpec>[
    _ToolSpec(
      name: 'list_files',
      description: '列出我工作区里某个目录的内容。目录在前，同类按名字排序。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description': '相对工作区根的目录路径。根目录用空串或 "."',
          },
        },
        'required': <String>[],
      },
      permissions: <String>['fs.read'],
    ),
    _ToolSpec(
      name: 'read_file',
      description: '读我工作区里的一个文本文件。读不了（比如是图片）会明确报错。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string', 'description': '相对工作区根的文件路径'},
        },
        'required': <String>['path'],
      },
      permissions: <String>['fs.read'],
    ),
    _ToolSpec(
      name: 'write_file',
      description: '在我的工作区里写文本文件。默认**不覆盖**已有文件；'
          '要修改已有文件必须显式传 overwrite: true。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{'type': 'string', 'description': '相对工作区根的文件路径'},
          'text': <String, dynamic>{'type': 'string', 'description': '文件内容'},
          'overwrite': <String, dynamic>{
            'type': 'boolean',
            'description': '是否允许覆盖已存在的文件。修改已有文件必须设为 true',
          },
        },
        'required': <String>['path', 'text'],
      },
      permissions: <String>['fs.write'],
    ),
    _ToolSpec(
      name: 'create_folder',
      description: '在我的工作区里新建一个文件夹。已存在就什么都不做。',
      parameters: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'path': <String, dynamic>{
            'type': 'string',
            'description': '相对工作区根的文件夹路径，可以多级（如 a/b/c）',
          },
        },
        'required': <String>['path'],
      },
      permissions: <String>['fs.write'],
    ),
  ];

  /// 执行一个宿主工具，返回给模型看的结果。
  ///
  /// 失败抛 [TsukiroException]，由调用方转成 `ToolInvocationResult.failure`。
  static Future<Object?> execute({
    required WorkspaceStore store,
    required String agentId,
    required String handler,
    required Map<String, dynamic> args,
  }) async {
    switch (handler) {
      case 'list_files':
        final path = (args['path'] as String?)?.trim() ?? '';
        final entries = await store.list(agentId, path);
        return <String, dynamic>{
          'path': path.isEmpty ? '.' : path,
          'count': entries.length,
          'entries': entries
              .map((e) => <String, dynamic>{
                    'name': e['name'],
                    'isDirectory': e['isDirectory'],
                    'size': e['size'],
                  })
              .toList(growable: false),
        };

      case 'read_file':
        final path = _requirePath(args);
        try {
          final text = await store.readText(agentId, path);
          return <String, dynamic>{'path': path, 'text': text};
        } on Object catch (e) {
          throw TsukiroException(
            TsukiroErrorCode.ioError,
            '读不了这个文件（可能不是文本，或不存在）：$e',
            details: <String, dynamic>{'path': path},
          );
        }

case 'create_folder':
        final path = _requirePath(args);
        await store.createDir(agentId, path);
        return <String, dynamic>{'path': path, 'created': true};

      case 'write_file':
        final path = _requirePath(args);
        final text = args['text'] as String?;
        if (text == null) {
          throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 text');
        }
        // **覆盖必须显式要求。**
        //
        // 直接允许覆盖的话，"写文件"这个动作会变得静默且不可逆：
        // 用户看不出来发生了什么，而 AI 会以为"我改好了"。
        //
        // 所以做成一个显式开关 —— 模型要改已有文件必须传
        // overwrite: true，这个参数会留在工具调用记录里，
        // 事后能查"它是不是有意覆盖的"。
        // **宽容解析。** 模型有时会把布尔值发成字符串或数字 ——
        // 严格比较 `== true` 会让它"传了还是不生效"，而错误信息又在叫它传，
        // 于是变成死循环（真实出现过）。
        final rawOverwrite = args['overwrite'];
        final overwrite = rawOverwrite == true ||
            rawOverwrite == 1 ||
            rawOverwrite == 'true' ||
            rawOverwrite == '1';

        // **先记下原来在不在。**
        //
        // 之前无条件返回 created: true —— 覆盖已有文件也说自己"新建"了，
        // 前端拿这个标志提示"新建成功"就会骗人。
        final existed = await store.exists(agentId, path);
        if (!overwrite && existed) {
          throw TsukiroException(
            TsukiroErrorCode.invalidArgs,
            '工作区里已经有「$path」了。要修改它请传 overwrite: true，'
            '否则换一个文件名。',
            details: <String, dynamic>{'path': path, 'exists': true},
          );
        }
        await store.writeText(agentId, path, text);
        return <String, dynamic>{
          'path': path,
          // **UTF-8 字节数，不是 String.length。**
          //
          // Dart 的 String.length 是 UTF-16 码元数：
          // 一个汉字算 1，但 UTF-8 里是 3 字节。之前报的数对中文
          // 只有实际的三分之一，跟文件大小对不上。
          'bytes': utf8.encode(text).length,
          'created': !existed,
          'overwritten': existed,
        };

      default:
        throw TsukiroException(
          TsukiroErrorCode.notFound,
          '宿主没有这个工具：$handler',
        );
    }
  }

  static String _requirePath(Map<String, dynamic> args) {
    final path = (args['path'] as String?)?.trim();
    if (path == null || path.isEmpty) {
      throw TsukiroException(TsukiroErrorCode.invalidArgs, '缺少 path');
    }
    return path;
  }
}

class _ToolSpec {
  const _ToolSpec({
    required this.name,
    required this.description,
    required this.parameters,
    required this.permissions,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final List<String> permissions;
}
