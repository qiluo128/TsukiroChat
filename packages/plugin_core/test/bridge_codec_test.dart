import 'dart:convert';

import 'package:plugin_core/plugin_core.dart';
import 'package:test/test.dart';

void main() {
  const codec = BridgeCodec();

  group('往返编解码', () {
    test('req', () {
      final original = BridgeEnvelope.request(
        id: 'r_1',
        method: 'sys.time',
        params: <String, dynamic>{'tz': 'Asia/Shanghai'},
      );
      final decoded = codec.decode(codec.encode(original));
      expect(decoded.kind, BridgeKind.req);
      expect(decoded.id, 'r_1');
      expect(decoded.method, 'sys.time');
      expect(decoded.params, <String, dynamic>{'tz': 'Asia/Shanghai'});
      expect(decoded.v, bridgeProtocolVersion);
    });

    test('res（含 null result）', () {
      final decoded = codec.decode(
        codec.encode(BridgeEnvelope.response(id: 'r_2', result: null)),
      );
      expect(decoded.kind, BridgeKind.res);
      expect(decoded.id, 'r_2');
      expect(decoded.result, isNull);
    });

    test('res（含嵌套结构）', () {
      final decoded = codec.decode(codec.encode(BridgeEnvelope.response(
        id: 'r_3',
        result: <String, dynamic>{
          'items': <dynamic>[
            <String, dynamic>{'a': 1},
          ],
          'ok': true,
        },
      )));
      expect((decoded.result as Map<String, dynamic>)['ok'], isTrue);
    });

    test('err', () {
      final decoded = codec.decode(codec.encode(BridgeEnvelope.failure(
        id: 'r_4',
        error: TsukiroException.permissionDenied('sys.time'),
      )));
      expect(decoded.kind, BridgeKind.err);
      expect(decoded.error!.code, TsukiroErrorCode.permissionDenied);
      expect(decoded.error!.retryable, isFalse);
      expect(decoded.error!.details['permission'], 'sys.time');
    });

    test('evt', () {
      final decoded = codec.decode(
        codec.encode(BridgeEnvelope.event('lifecycle.start', <String, dynamic>{'reason': 'install'})),
      );
      expect(decoded.kind, BridgeKind.evt);
      expect(decoded.method, 'lifecycle.start');
      expect(decoded.id, isNull);
    });

    test('str', () {
      final decoded = codec.decode(codec.encode(BridgeEnvelope.streamChunk(
        id: 'r_5',
        seq: 7,
        delta: '你好',
      )));
      expect(decoded.kind, BridgeKind.str);
      expect(decoded.seq, 7);
      expect(decoded.delta, '你好');
      expect(decoded.done, isFalse);
    });

    test('inv', () {
      final decoded = codec.decode(codec.encode(BridgeEnvelope.invoke(
        id: 'i_1',
        method: 'tool.invoke',
        params: <String, dynamic>{
          'tool': 'get_time',
          'args': <String, dynamic>{},
          'callId': 'call_abc',
        },
      )));
      expect(decoded.kind, BridgeKind.inv);
      expect(decoded.method, 'tool.invoke');
    });

    test('编解码自动补 ts', () {
      final decoded = codec.decode(
        codec.encode(BridgeEnvelope.event('ping')),
      );
      expect(decoded.ts, isNotNull);
      expect(decoded.ts, greaterThan(0));
    });
  });

  group('大小限制', () {
    test('按 UTF-8 字节数算，而不是字符数', () {
      // '你' 是 3 字节。1000 个汉字 = 3000 字节，远小于 1MB，应通过
      final small = BridgeEnvelope.event('a', <String, dynamic>{'x': '你' * 1000});
      expect(() => codec.encode(small), returnsNormally);

      // 但 40 万个汉字 = 1.2MB，应被拒
      final big = BridgeEnvelope.event('a', <String, dynamic>{'x': '你' * 400000});
      expect(
        () => codec.encode(big),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.invalidArgs,
        )),
      );
    });

    test('decode 也检查大小', () {
      final huge = '{"v":1,"kind":"evt","method":"a","params":{"x":"${'a' * (1024 * 1024 + 10)}"}}';
      expect(() => codec.decode(huge), throwsA(isA<TsukiroException>()));
    });

    test('自定义上限生效', () {
      const tiny = BridgeCodec(maxBytes: 64);
      expect(
        () => tiny.encode(BridgeEnvelope.event('a', <String, dynamic>{'x': 'y' * 100})),
        throwsA(isA<TsukiroException>()),
      );
    });
  });

  group('协议版本', () {
    test('低于等于当前版本都接受', () {
      expect(codec.decode('{"v":1,"kind":"evt","method":"ping"}').v, 1);
    });

    test('高于当前版本被拒（不尽力解析）', () {
      expect(
        () => codec.decode('{"v":99,"kind":"evt","method":"ping"}'),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.unsupported,
        )),
      );
    });

    test('缺少 v 被拒', () {
      expect(() => codec.decode('{"kind":"evt","method":"ping"}'),
          throwsA(isA<TsukiroException>()));
    });
  });

  group('结构校验', () {
    test('非对象顶层被拒', () {
      expect(() => codec.decode('[]'), throwsA(isA<TsukiroException>()));
      expect(() => codec.decode('"x"'), throwsA(isA<TsukiroException>()));
    });

    test('非法 JSON 被拒', () {
      expect(() => codec.decode('{ 坏 }'), throwsA(isA<TsukiroException>()));
    });

    test('未知 kind 被拒', () {
      expect(() => codec.decode('{"v":1,"kind":"乱写"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('req 缺 id 或 method 被拒', () {
      expect(() => codec.decode('{"v":1,"kind":"req","method":"sys.time"}'),
          throwsA(isA<TsukiroException>()));
      expect(() => codec.decode('{"v":1,"kind":"req","id":"r1"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('inv 缺 method 被拒', () {
      expect(() => codec.decode('{"v":1,"kind":"inv","id":"i1"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('err 缺 error 对象被拒', () {
      expect(() => codec.decode('{"v":1,"kind":"err","id":"r1"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('evt 缺 method 被拒', () {
      expect(() => codec.decode('{"v":1,"kind":"evt"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('str 的 seq 必须是非负数字', () {
      expect(() => codec.decode('{"v":1,"kind":"str","id":"r1","seq":-1}'),
          throwsA(isA<TsukiroException>()));
      expect(() => codec.decode('{"v":1,"kind":"str","id":"r1","seq":"0"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('str 分片数超上限被拒', () {
      expect(
        () => codec.decode('{"v":1,"kind":"str","id":"r1","seq":999999}'),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.rateLimited,
        )),
      );
    });

    test('params 非对象被拒', () {
      expect(() => codec.decode('{"v":1,"kind":"req","id":"r1","method":"m","params":"x"}'),
          throwsA(isA<TsukiroException>()));
    });

    test('未知错误码降级为 INTERNAL 而不是崩溃', () {
      final decoded = codec.decode(
        '{"v":1,"kind":"err","id":"r1","error":{"code":"FUTURE_CODE","message":"x"}}',
      );
      expect(decoded.error!.code, TsukiroErrorCode.internal);
      expect(decoded.error!.message, 'x');
    });

    test('错误码字符串与枚举互转一致', () {
      for (final code in TsukiroErrorCode.values) {
        expect(errorCodeFromString(errorCodeToString(code)), code);
      }
      expect(errorCodeFromString('不存在的码'), isNull);
    });
  });

  group('请求 id 配对', () {
    test('生成单调递增且带前缀的 id', () {
      final reg = PendingCallRegistry();
      final a = reg.nextId();
      final b = reg.nextId();
      final c = reg.nextId(prefix: 'i');
      expect(a, startsWith('r_'));
      expect(c, startsWith('i_'));
      expect(a, isNot(b));
    });

    test('register / take 配对', () {
      final reg = PendingCallRegistry();
      final id = reg.nextId();
      reg.register(id, 'sys.time');
      expect(reg.isPending(id), isTrue);
      expect(reg.take(id), 'sys.time');
      expect(reg.isPending(id), isFalse);
    });

    test('重复 take 返回 null（可能是伪造或重复响应）', () {
      final reg = PendingCallRegistry();
      final id = reg.nextId();
      reg.register(id, 'm');
      expect(reg.take(id), 'm');
      expect(reg.take(id), isNull);
    });

    test('并发 100 个请求能各自配对', () {
      final reg = PendingCallRegistry(maxPending: 200);
      final ids = <String, String>{};
      for (var i = 0; i < 100; i++) {
        final id = reg.nextId();
        ids[id] = 'method_$i';
        reg.register(id, 'method_$i');
      }
      expect(reg.pendingCount, 100);
      ids.forEach((id, method) {
        expect(reg.take(id), method, reason: 'id $id 应配对到 $method');
      });
      expect(reg.pendingCount, 0);
    });

    test('超出上限抛 RATE_LIMITED', () {
      final reg = PendingCallRegistry(maxPending: 2);
      reg.register(reg.nextId(), 'a');
      reg.register(reg.nextId(), 'b');
      expect(
        () => reg.register(reg.nextId(), 'c'),
        throwsA(isA<TsukiroException>().having(
          (e) => e.code,
          'code',
          TsukiroErrorCode.rateLimited,
        )),
      );
    });

    test('clear 返回全部悬挂 id（插件崩溃时用）', () {
      final reg = PendingCallRegistry();
      reg.register(reg.nextId(), 'a');
      reg.register(reg.nextId(), 'b');
      expect(reg.clear(), hasLength(2));
      expect(reg.pendingCount, 0);
    });
  });

  group('流式分片序号校验', () {
    test('顺序分片全部接受', () {
      final v = StreamSequenceValidator();
      for (var i = 0; i < 5; i++) {
        expect(v.accept(i), isTrue);
      }
      expect(v.expected, 5);
    });

    test('丢包被检出', () {
      final v = StreamSequenceValidator();
      expect(v.accept(0), isTrue);
      expect(v.accept(2), isFalse, reason: '跳过了 seq=1');
      // 检测到异常后不推进，仍期待 1
      expect(v.expected, 1);
    });

    test('重复分片被检出', () {
      final v = StreamSequenceValidator();
      expect(v.accept(0), isTrue);
      expect(v.accept(0), isFalse);
    });

    test('reset 重置', () {
      final v = StreamSequenceValidator();
      v.accept(0);
      v.reset();
      expect(v.expected, 0);
      expect(v.accept(0), isTrue);
    });
  });

  group('编码结果可被 JSON 解析', () {
    test('含中文与特殊字符的载荷', () {
      final text = codec.encode(BridgeEnvelope.response(
        id: 'r1',
        result: <String, dynamic>{
          'text': '换行\n引号"反斜杠\\Unicode ✓',
        },
      ));
      final parsed = jsonDecode(text) as Map<String, dynamic>;
      expect((parsed['result'] as Map<String, dynamic>)['text'],
          '换行\n引号"反斜杠\\Unicode ✓');
    });
  });
}
