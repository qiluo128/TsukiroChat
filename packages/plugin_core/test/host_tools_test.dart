/// 宿主工具的注册与授权。
///
/// 这一组的关键不是"宿主工具能用"，而是**两条防退化测试**：
///
///   1. 插件工具仍然受门禁管
///   2. 未知 pluginId 仍然被拒
///
/// 加一个"放行宿主"的改动，最容易顺手把"放行所有人"也带进来。
/// 而那正是权限系统最不该发生的退化。
library;

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

/// 造一个宿主工具。
RegisteredTool hostTool(
  String name, {
  List<String> permissions = const <String>[],
}) {
  return RegisteredTool(
    name: name,
    originalName: name,
    description: '测试工具 $name',
    parameters: const <String, dynamic>{'type': 'object', 'properties': <String, dynamic>{}},
    pluginId: hostPluginId,
    pluginVersion: '0.0.0-test',
    handler: name,
    permissions: permissions,
    timeoutMs: 5000,
    dangerous: false,
    exposed: true,
  );
}

void main() {
  group('ToolRegistry.registerHostTool', () {
    test('注册后能被查到', () {
      final reg = ToolRegistry()..registerHostTool(hostTool('read_file'));
      final tool = reg.lookup('read_file');
      expect(tool, isNotNull);
      expect(tool!.pluginId, hostPluginId);
      expect(reg.toolNamesOf(hostPluginId), contains('read_file'));
    });

    test('出现在给模型的工具定义里', () {
      final reg = ToolRegistry()..registerHostTool(hostTool('read_file'));
      final gate = Gatekeeper()..registerHost(<String>{});
      final defs = reg.toOpenAiTools(gatekeeper: gate);
      final names = defs.map((d) => (d['function'] as Map)['name']).toList();
      expect(names, contains('read_file'));
    });

    test('pluginId 不是 __host__ 会被拒', () {
      final reg = ToolRegistry();
      expect(
        () => reg.registerHostTool(RegisteredTool(
          name: 'x',
          originalName: 'x',
          description: 'x',
          parameters: const <String, dynamic>{},
          // 故意用插件 id —— 宿主工具伪装成插件会让权限模型变形
          pluginId: 'dev.someone.plugin',
          pluginVersion: '1.0.0',
          handler: 'x',
          permissions: const <String>[],
          timeoutMs: 1000,
          dangerous: false,
          exposed: true,
        )),
        throwsArgumentError,
      );
    });

    test('重名直接抛错，不静默改名', () {
      final reg = ToolRegistry()..registerHostTool(hostTool('read_file'));
      expect(() => reg.registerHostTool(hostTool('read_file')), throwsArgumentError,
          reason: '插件重名是运行时情况可以改名；宿主重名是编程错误，改名只会让人找不到工具');
    });

    test('注销宿主工具后不可见', () {
      final reg = ToolRegistry()..registerHostTool(hostTool('read_file'));
      reg.unregisterPlugin(hostPluginId);
      expect(reg.lookup('read_file'), isNull);
    });
  });

  group('Gatekeeper.registerHost', () {
    test('声明过的 install 级权限放行', () {
      final gate = Gatekeeper()..registerHost(<String>{'fs.read'});
      final r = gate.check(hostPluginId, 'fs.read');
      expect(r.isAllowed, isTrue);
      expect(r.decision, GateDecision.allow);
    });

    test('**没声明的权限仍然被拒**（宿主不是免检）', () {
      final gate = Gatekeeper()..registerHost(<String>{'fs.read'});
      final r = gate.check(hostPluginId, 'fs.write');
      expect(r.isAllowed, isFalse);
      expect(r.decision, GateDecision.notDeclared);
    });

    test('**confirm 级仍然要求确认**（宿主也要问用户）', () {
      final gate = Gatekeeper()..registerHost(<String>{'media.read'});
      final r = gate.check(hostPluginId, 'media.read');
      expect(r.isAllowed, isFalse);
      expect(r.decision, GateDecision.confirmRequired,
          reason: '宿主登记的是"我声明并持有"，不是"确认级对我无效"');
    });

    test('未登记时是未知插件（fail-closed）', () {
      final gate = Gatekeeper();
      final r = gate.check(hostPluginId, 'fs.read');
      expect(r.decision, GateDecision.unknownPlugin);
    });
  });

  group('防退化：别的身份没有被放宽', () {
    test('插件没声明就调不了', () {
      final gate = Gatekeeper();
      final r = gate.check('dev.someone.plugin', 'fs.read');
      expect(r.decision, GateDecision.unknownPlugin,
          reason: '未注册的插件必须被拒 —— 加宿主支持不能顺手让路人也能调');
    });

    test('插件声明了但没授予，仍然被拒', () {
      final gate = Gatekeeper();
      gate.registerPlugin('dev.other.plugin', <String>['fs.read']);
      final r = gate.check('dev.other.plugin', 'fs.read');
      expect(r.decision, GateDecision.notGranted,
          reason: '声明即上限，但声明 ≠ 授予');
    });

    test('宿主登记不影响插件', () {
      final gate = Gatekeeper()..registerHost(<String>{'fs.read', 'fs.write'});
      gate.registerPlugin('dev.other.plugin', <String>['fs.write']);
      expect(gate.check('dev.other.plugin', 'fs.write').decision,
          GateDecision.notGranted);
      expect(gate.check(hostPluginId, 'fs.write').isAllowed, isTrue);
    });

    test('未知 pluginId 一律 unknownPlugin', () {
      final gate = Gatekeeper()..registerHost(<String>{'fs.read'});
      expect(gate.check('', 'fs.read').decision, isNot(GateDecision.allow));
      expect(gate.check('nobody', 'fs.read').decision, GateDecision.unknownPlugin);
    });
  });
}
