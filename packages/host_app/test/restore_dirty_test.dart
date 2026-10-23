/// `restore` 的两道保护。
///
/// 这个文件的理由：**恢复是不可逆的覆盖**。
///
/// 用户报过一个真实问题 —— `restore_version` 不校验「当前内容是否被
/// 外部改过」，于是"恢复"会静默丢掉那些改动。数据丢了没有撤销。
///
/// 所以这里锁两件事：
///   1. 当前内容和版本库不一致 → DIRTY_WORKSPACE，除非 force
///   2. 二进制内容不能按文本恢复（原来用 allowMalformed 会静默损坏）
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:plugin_core/plugin_core.dart';
import 'package:tsukiro_chat/services/workspace_store.dart';

void main() {
  late Directory tmp;
  late WorkspaceStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tsukiro-restore-');
    store = WorkspaceStore.testAt(p.join(tmp.path, 'workspaces'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<String> write(String text) async {
    await store.writeText('agent1', 'a.txt', text);
    final h = await store.versionsFor('agent1').history('a.txt');
    return h.first.sha;
  }

  test('正常恢复：当前内容就是最新记录 → 允许', () async {
    final v1 = await write('one');
    await write('two');
    await store.restore('agent1', 'a.txt', v1);
    expect(await store.readText('agent1', 'a.txt'), 'one');
  });

  test('当前内容被外部改过 → DIRTY_WORKSPACE', () async {
    final v1 = await write('one');
    await write('two');

    // 绕过版本库直接改文件（模拟别的途径改了它）
    final abs = store.resolve('agent1', 'a.txt');
    File(abs).writeAsStringSync('external edit');

    await expectLater(
      store.restore('agent1', 'a.txt', v1),
      throwsA(isA<TsukiroException>().having(
        (e) => e.code, 'code', TsukiroErrorCode.dirtyWorkspace)),
    );

    // **关键断言：文件没被动过。**
    // 抛异常但内容已经改了，那这道保护就白做了。
    expect(File(abs).readAsStringSync(), 'external edit');
  });

  test('force: true 时允许覆盖', () async {
    final v1 = await write('one');
    await write('two');
    final abs = store.resolve('agent1', 'a.txt');
    File(abs).writeAsStringSync('external edit');

    await store.restore('agent1', 'a.txt', v1, force: true);
    expect(await store.readText('agent1', 'a.txt'), 'one');
  });

  test('恢复本身进历史（可再撤销）', () async {
    final v1 = await write('one');
    await write('two');
    await store.restore('agent1', 'a.txt', v1);
    final h = await store.versionsFor('agent1').history('a.txt');
    expect(h.first.source, 'restore');
  });

  test('二进制内容不能按文本恢复（不能 allowMalformed 糊过去）', () async {
    // 直接往版本库塞非 UTF-8 字节
    final versions = store.versionsFor('agent1');
    final sha = await versions.putBlob(<int>[0xff, 0xfe, 0x00, 0x80]);
    await versions.record('bin.dat', sha, bytes: 4, source: 'write');

    await expectLater(
      store.restore('agent1', 'bin.dat', sha, force: true),
      throwsA(isA<TsukiroException>().having(
        (e) => e.code, 'code', TsukiroErrorCode.unsupported)),
    );
  });

  test('找不到的版本 → NOT_FOUND', () async {
    await write('one');
    await expectLater(
      store.restore('agent1', 'a.txt', '0' * 64),
      throwsA(isA<TsukiroException>().having(
        (e) => e.code, 'code', TsukiroErrorCode.notFound)),
    );
  });

  test('UTF-8 中文能无损还原', () async {
    const text = '第一行\n第二行 🎉\n';
    final v1 = await write(text);
    await write('改过了');
    await store.restore('agent1', 'a.txt', v1);
    expect(await store.readText('agent1', 'a.txt'), text);
    // 字节完全一致，不是"看起来一样"
    expect(utf8.encode(await store.readText('agent1', 'a.txt')), utf8.encode(text));
  });
}
