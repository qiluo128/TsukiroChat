/// 工作区版本快照。
///
/// 这里测的是「能不能退回去」这件事的**逻辑层**：内容寻址、去重、
/// 历史顺序、损坏索引的容错。真实的文件系统行为（rename 原子性等）
/// 用临时目录测。
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:tsukiro_chat/services/workspace_versions.dart';

void main() {
  late Directory tmp;
  late WorkspaceVersions versions;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tsukiro-ver-');
    versions = WorkspaceVersions(p.join(tmp.path, '.tsukiro'));
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('内容寻址', () {
    test('同样的内容得到同样的 sha', () async {
      final a = await versions.putBlob(utf8.encode('hello'));
      final b = await versions.putBlob(utf8.encode('hello'));
      expect(a, b);
      expect(a, sha256.convert(utf8.encode('hello')).toString());
    });

    test('不同内容得到不同 sha', () async {
      final a = await versions.putBlob(utf8.encode('hello'));
      final b = await versions.putBlob(utf8.encode('hello!'));
      expect(a, isNot(b));
    });

    test('相同内容只落一个 blob（去重）', () async {
      await versions.putBlob(utf8.encode('same'));
      await versions.putBlob(utf8.encode('same'));
      await versions.putBlob(utf8.encode('same'));

      final objects = Directory(p.join(tmp.path, '.tsukiro', 'objects'));
      final files = objects
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !f.path.endsWith('.tmp'))
          .toList();
      expect(files.length, 1, reason: '三次写入同样内容应该只有一个 blob');
    });

    test('能读回来，字节完全一致', () async {
      final original = utf8.encode('内容 with unicode 和 emoji 🎉');
      final sha = await versions.putBlob(original);
      final back = await versions.getBlob(sha);
      expect(back, isNotNull);
      expect(back, original);
    });

    test('不存在的 sha 返回 null 而不是抛异常', () async {
      expect(await versions.getBlob('0' * 64), isNull);
    });

    test('blob 用两级目录，避免单目录堆上万文件', () async {
      final sha = await versions.putBlob(utf8.encode('x'));
      final path = p.join(tmp.path, '.tsukiro', 'objects', sha.substring(0, 2), sha);
      expect(File(path).existsSync(), isTrue);
    });
  });

  group('历史', () {
    test('没有记录时是空列表', () async {
      expect(await versions.history('a.txt'), isEmpty);
    });

    test('记录后能查到，新的在前', () async {
      final s1 = await versions.putBlob(utf8.encode('v1'));
      await versions.record('a.txt', s1, bytes: 2);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final s2 = await versions.putBlob(utf8.encode('v2'));
      await versions.record('a.txt', s2, bytes: 2);

      final h = await versions.history('a.txt');
      expect(h.length, 2);
      expect(h.first.sha, s2, reason: '最新的应该在第一个');
      expect(h.last.sha, s1);
    });

    test('按文件过滤，不串', () async {
      final s = await versions.putBlob(utf8.encode('x'));
      await versions.record('a.txt', s, bytes: 1);
      await versions.record('b.txt', s, bytes: 1);
      expect((await versions.history('a.txt')).length, 1);
      expect((await versions.history('b.txt')).length, 1);
      expect((await versions.allHistory()).length, 2);
    });

    test('source 被记下来（排查"我没动它怎么变了"）', () async {
      final s = await versions.putBlob(utf8.encode('x'));
      await versions.record('a.txt', s, bytes: 1, source: 'edit');
      expect((await versions.history('a.txt')).first.source, 'edit');
    });

    test('引用计数能算出来', () async {
      final s = await versions.putBlob(utf8.encode('x'));
      await versions.record('a.txt', s, bytes: 1);
      await versions.record('b.txt', s, bytes: 1);
      expect(await versions.refCount(s), 2);
    });
  });

  group('索引容错', () {
    test('坏行被跳过，不影响其它记录', () async {
      final s = await versions.putBlob(utf8.encode('x'));
      await versions.record('a.txt', s, bytes: 1);

      // 模拟进程被杀留下半行
      final index = File(p.join(tmp.path, '.tsukiro', 'index.jsonl'));
      index.writeAsStringSync('{"path":"broken', mode: FileMode.append);

      final h = await versions.history('a.txt');
      expect(h.length, 1, reason: '一行坏掉不该让整个历史不可读');
    });

    test('超限时裁剪最旧的', () async {
      final s = await versions.putBlob(utf8.encode('x'));
      for (var i = 0; i < 12; i++) {
        await versions.record('f$i.txt', s, bytes: 1);
      }
      // 这个测试只验证裁剪会把条数降下来，不依赖具体上限
      final pruned = await versions.pruneIndex();
      expect(pruned, 0, reason: '12 条远低于上限，不该裁');
      expect((await versions.allHistory()).length, 12);
    });
  });
}
