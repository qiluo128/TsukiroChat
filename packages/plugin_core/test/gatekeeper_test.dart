import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  late Gatekeeper gk;
  const pluginId = 'dev.tsukiro.time';

  setUp(() {
    gk = Gatekeeper();
    gk.registerPlugin(pluginId, <String>['sys.time', 'model.chat']);
    gk.grant(pluginId, 'sys.time');
  });

  group('注册', () {
    test('过滤未知权限并返回它们（不静默忽略）', () {
      final g = Gatekeeper();
      final unknown = g.registerPlugin('a.b', <String>['sys.time', 'sys.tim', '瞎写的']);
      expect(unknown, containsAll(<String>['sys.tim', '瞎写的']));
      expect(g.declaredOf('a.b'), <String>{'sys.time'});
    });

    test('未注册插件 isRegistered 为 false', () {
      expect(gk.isRegistered('不存在'), isFalse);
    });

    test('unregister 后插件与授权都清掉', () {
      gk.unregisterPlugin(pluginId);
      expect(gk.isRegistered(pluginId), isFalse);
      expect(gk.grantedOf(pluginId), isEmpty);
    });
  });

  group('授权', () {
    test('只能授予已声明的权限', () {
      expect(gk.grant(pluginId, 'model.chat'), isTrue);
      expect(gk.grant(pluginId, 'media.read'), isFalse,
          reason: '未声明的权限不允许授予（声明即上限）');
    });

    test('grantAll 返回实际成功的列表', () {
      final granted = gk.grantAll(pluginId, <String>['model.chat', 'media.read']);
      expect(granted, <String>['model.chat']);
    });

    test('撤销单个权限', () {
      expect(gk.revoke(pluginId, 'sys.time'), isTrue);
      expect(gk.grantedOf(pluginId), isEmpty);
    });

    test('revokeAll 返回被撤销列表', () {
      gk.grant(pluginId, 'model.chat');
      final revoked = gk.revokeAll(pluginId);
      expect(revoked, containsAll(<String>['sys.time', 'model.chat']));
      expect(gk.grantedOf(pluginId), isEmpty);
    });
  });

  group('check —— 判定顺序即安全策略', () {
    test('已声明且已授予 → allow', () {
      final r = gk.check(pluginId, 'sys.time');
      expect(r.isAllowed, isTrue);
      expect(r.decision, GateDecision.allow);
    });

    test('未注册插件 → unknownPlugin', () {
      final r = gk.check('不存在', 'sys.time');
      expect(r.decision, GateDecision.unknownPlugin);
      expect(r.isAllowed, isFalse);
    });

    test('未知权限名 → unknownPermission（fail-closed）', () {
      gk.registerPlugin('a.b', <String>[]);
      final r = gk.check('a.b', 'sys.tim');
      expect(r.decision, GateDecision.unknownPermission);
    });

    test('已声明但未授予 → notGranted', () {
      final r = gk.check(pluginId, 'model.chat');
      expect(r.decision, GateDecision.notGranted);
      expect(r.isAllowed, isFalse);
    });

    test('未声明 → notDeclared（声明即上限）', () {
      // 权限目录里存在 sys.info，但本插件没声明
      final r = gk.check(pluginId, 'sys.info');
      expect(r.decision, GateDecision.notDeclared);
    });

    test('声明即上限：A 的授权不能给 B 用', () {
      gk.registerPlugin('dev.tsukiro.other', <String>['sys.time']);
      // B 声明了但没授予
      expect(gk.check('dev.tsukiro.other', 'sys.time').decision,
          GateDecision.notGranted);
      // 给 B 授予后各自独立
      gk.grant('dev.tsukiro.other', 'sys.time');
      expect(gk.check('dev.tsukiro.other', 'sys.time').isAllowed, isTrue);
      gk.revoke('dev.tsukiro.other', 'sys.time');
      expect(gk.check(pluginId, 'sys.time').isAllowed, isTrue,
          reason: '撤销 B 不应影响 A');
    });

    test('confirm 级权限返回 confirmRequired，而不是直接放行', () {
      gk.registerPlugin('a.b', <String>['screen.capture']);
      gk.grant('a.b', 'screen.capture');
      final r = gk.check('a.b', 'screen.capture');
      expect(r.decision, GateDecision.confirmRequired);
      expect(r.isAllowed, isFalse);
      expect(r.needsConfirmation, isTrue);
    });

    test('无需权限的原语（permission 为 null）也能通过', () {
      final r = gk.check(pluginId, null);
      expect(r.isAllowed, isTrue);
    });

    test('未注册插件调无需权限的原语也要被拦', () {
      final r = gk.check('不存在', null);
      expect(r.isAllowed, isFalse);
      expect(r.decision, GateDecision.unknownPlugin);
    });
  });

  group('撤销立即生效', () {
    test('授权 → 通过 → 撤销 → PERMISSION_REVOKED', () {
      expect(gk.check(pluginId, 'sys.time').isAllowed, isTrue);

      gk.revoke(pluginId, 'sys.time');

      final after = gk.check(pluginId, 'sys.time');
      expect(after.isAllowed, isFalse);
      expect(after.decision, GateDecision.notGranted);

      final ex = after.toException();
      expect(ex.code, TsukiroErrorCode.permissionDenied);
      expect(ex.retryable, isFalse);
    });

    test('isAllowed 为 true 时 toException 抛 StateError（调用方误用）', () {
      final r = gk.check(pluginId, 'sys.time');
      expect(() => r.toException(), throwsStateError);
    });
  });

  group('安装期校验', () {
    test('未知权限被拒', () {
      expect(gk.validateForInstall(<String>['sys.time', '瞎写']), <String>['瞎写']);
    });

    test('全部合法时返回空列表', () {
      expect(gk.validateForInstall(<String>['sys.time', 'a11y']), isEmpty);
    });
  });

  group('按原语名校验', () {
    test('checkPrimitive 内部查映射表', () {
      expect(gk.checkPrimitive(pluginId, 'sys.time').isAllowed, isTrue);
      expect(gk.checkPrimitive(pluginId, 'model.chat').decision,
          GateDecision.notGranted);
      expect(gk.checkPrimitive(pluginId, 'state.get').isAllowed, isTrue);
    });
  });

  group('effectivePermissions', () {
    test('等于已声明 ∩ 已授予', () {
      gk.grant(pluginId, 'model.chat');
      expect(gk.effectivePermissions(pluginId),
          <String>{'sys.time', 'model.chat'});
      gk.revoke(pluginId, 'model.chat');
      expect(gk.effectivePermissions(pluginId), <String>{'sys.time'});
    });
  });

  group('持久化', () {
    test('export/import 往返一致', () {
      gk.grant(pluginId, 'model.chat');
      final state = gk.exportState();

      final restored = Gatekeeper()..importState(state);
      expect(restored.isRegistered(pluginId), isTrue);
      expect(restored.grantedOf(pluginId), <String>{'sys.time', 'model.chat'});
      expect(restored.check(pluginId, 'sys.time').isAllowed, isTrue);
    });
  });

  group('热路径（不做 IO）', () {
    test('一万次 check 应极快完成', () {
      final sw = Stopwatch()..start();
      for (var i = 0; i < 10000; i++) {
        gk.check(pluginId, 'sys.time');
      }
      sw.stop();
      // 内存查表，一万次远低于 1 秒。这里给足余量避免 CI 抖动误报。
      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: 'check 是每次原语调用都会走的热路径，不能有 IO');
    });
  });
}
