import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  group('权限目录', () {
    test('查表命中', () {
      expect(lookupPermission('sys.time')?.level, PermissionLevel.install);
      expect(lookupPermission('a11y')?.level, PermissionLevel.confirm);
      expect(lookupPermission('不存在')?.level, isNull);
    });

    test('未知权限级别 fail-closed 为 denied', () {
      expect(levelOf('不存在的权限'), PermissionLevel.denied);
    });

    test('目录里没有 denied 级权限（宿主保留项当前为空）', () {
      final denied = permissionCatalog.entries
          .where((e) => e.value.level == PermissionLevel.denied)
          .map((e) => e.key)
          .toList();
      expect(denied, isEmpty,
          reason: '若有 denied 级权限，需同步更新 docs/06-permissions.md');
    });

    test('高风险权限必须是 confirm 级', () {
      const mustConfirm = <String>[
        'a11y',
        'screen.capture',
        'screen.record',
        'sms.send',
        'sms.read',
        'call.make',
        'contact.read',
        'notification.read',
        'media.read',
        'media.camera',
        'media.microphone',
        'location',
        'sys.clipboard.read',
      ];
      for (final p in mustConfirm) {
        expect(levelOf(p), PermissionLevel.confirm, reason: '$p 应为 confirm 级');
      }
    });

    test('每个权限的 description 非空', () {
      for (final spec in permissionCatalog.values) {
        expect(spec.description.trim(), isNotEmpty, reason: spec.name);
      }
    });
  });

  group('原语 → 权限映射', () {
    test('无需权限的域', () {
      expect(requiredPermissionFor('state.get'), isNull);
      expect(requiredPermissionFor('crypto.hash'), isNull);
      expect(requiredPermissionFor('log.info'), isNull);
      expect(requiredPermissionFor('event.on'), isNull);
      expect(requiredPermissionFor('tool.list'), isNull);
    });

    test('sys 域按原语拆分', () {
      expect(requiredPermissionFor('sys.time'), 'sys.time');
      expect(requiredPermissionFor('sys.battery'), 'sys.info');
      expect(requiredPermissionFor('sys.network'), 'sys.info');
      expect(requiredPermissionFor('sys.device'), 'sys.info');
      expect(requiredPermissionFor('sys.locale'), 'sys.info');
      expect(requiredPermissionFor('sys.vibrate'), 'sys.clipboard.write');
      expect(requiredPermissionFor('sys.clipboard.read'), 'sys.clipboard.read');
    });

    test('model 域一律映射到 model.chat', () {
      expect(requiredPermissionFor('model.chat'), 'model.chat');
      expect(requiredPermissionFor('model.embed'), 'model.chat');
      expect(requiredPermissionFor('model.vision'), 'model.chat');
    });

    test('media.camera 与 audio.record 特例', () {
      expect(requiredPermissionFor('media.camera.capture'), 'media.camera');
      expect(requiredPermissionFor('media.camera.record'), 'media.camera');
      expect(requiredPermissionFor('media.audio.record'), 'media.microphone');
      expect(requiredPermissionFor('media.listPhotos'), 'media.read');
    });

    test('notification 特例', () {
      expect(requiredPermissionFor('notification.send'), 'notification.send');
      expect(requiredPermissionFor('notification.cancel'), 'notification.send');
      expect(requiredPermissionFor('notification.listen'), 'notification.read');
    });

    test('calendar 读写分离', () {
      expect(requiredPermissionFor('calendar.list'), 'calendar.read');
      expect(requiredPermissionFor('calendar.create'), 'calendar.write');
      expect(requiredPermissionFor('calendar.update'), 'calendar.write');
    });

    test('app.open 映射到 app.launch', () {
      expect(requiredPermissionFor('app.open'), 'app.launch');
      expect(requiredPermissionFor('app.list'), 'app.read');
    });

    test('映射结果必须在权限目录中存在', () {
      const primitives = <String>[
        'fs.read', 'fs.write', 'fs.delete', 'sys.time', 'sys.info',
        'sys.clipboard.read', 'sys.clipboard.write', 'media.read',
        'media.camera.capture', 'media.audio.record', 'contact.list',
        'sms.send', 'sms.list', 'call.make', 'calendar.list', 'calendar.create',
        'app.list', 'app.open', 'notification.send', 'notification.listen',
        'location.get', 'net.request', 'ui.toast', 'ui.overlay.show',
        'model.chat', 'a11y.find', 'screen.capture', 'screen.record', 'mcp.serve',
      ];
      for (final p in primitives) {
        final perm = requiredPermissionFor(p);
        expect(perm, isNotNull, reason: '$p 应有权限映射');
        expect(isKnownPermission(perm!), isTrue, reason: '$p → $perm 不在目录中');
      }
    });

    test('不变量：目录里每个权限名映射到自身', () {
      // 这条不变量能永久挡住「media.read 落到域名兜底变成不存在的 media」这类 bug
      for (final name in permissionCatalog.keys) {
        expect(requiredPermissionFor(name), name, reason: '权限 $name 应映射到自身');
      }
    });

    test('未知域 fail-closed：返回域名而非 null', () {
      // 返回域名 → 该名字不在目录中 → 守门人判 unknownPermission 并拒绝。
      // 若返回 null 就等于「无需权限」，那是 fail-open，绝不能这样。
      expect(requiredPermissionFor('futureDomain.doThing'), 'futureDomain');
      expect(isKnownPermission(requiredPermissionFor('futureDomain.doThing')!),
          isFalse);
    });

    test('非法原语名返回 null 而不是崩溃', () {
      expect(requiredPermissionFor(''), isNull);
      expect(requiredPermissionFor('没有点号'), isNull);
      expect(requiredPermissionFor('.'), isNull);
    });
  });
}
