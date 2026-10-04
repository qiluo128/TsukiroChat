/// 工具模型的标题清理测试。
///
/// 这层清理**必须由宿主做**，不能指望提示词 ——
/// 换个模型就不灵了，而模型输出跑偏是常态而不是异常。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tsukiro_chat/services/utility_model.dart';

void main() {
  group('标题清理', () {
    test('原样通过正常的标题', () {
      expect(UtilityModelService.cleanTitle('周末计划'), '周末计划');
    });

    test('去掉「标题：」前缀（中英文、大小写）', () {
      expect(UtilityModelService.cleanTitle('标题：周末计划'), '周末计划');
      expect(UtilityModelService.cleanTitle('标题: 周末计划'), '周末计划');
      expect(UtilityModelService.cleanTitle('Title: Weekend plan'), 'Weekend plan');
      expect(UtilityModelService.cleanTitle('题目：周末计划'), '周末计划');
    });

    test('去掉包裹的引号（中英文都去）', () {
      expect(UtilityModelService.cleanTitle('"周末计划"'), '周末计划');
      expect(UtilityModelService.cleanTitle('「周末计划」'), '周末计划');
      expect(UtilityModelService.cleanTitle('『周末计划』'), '周末计划');
      expect(UtilityModelService.cleanTitle('“周末计划”'), '周末计划');
      expect(UtilityModelService.cleanTitle('《周末计划》'), '周末计划');
      expect(UtilityModelService.cleanTitle("'周末计划'"), '周末计划');
    });

    test('只取第一行（模型爱附送理由）', () {
      expect(
        UtilityModelService.cleanTitle('周末计划\n理由：用户问了周末安排'),
        '周末计划',
      );
    });

    test('去掉结尾标点', () {
      expect(UtilityModelService.cleanTitle('周末计划。'), '周末计划');
      expect(UtilityModelService.cleanTitle('周末计划！'), '周末计划');
      expect(UtilityModelService.cleanTitle('Weekend plan.'), 'Weekend plan');
    });

    test('组合场景', () {
      expect(
        UtilityModelService.cleanTitle('标题：「周末计划」。\n说明：……'),
        '周末计划',
      );
    });

    test('超长时硬截断（提示词说了 12 字，模型不一定听）', () {
      final long = '这是一个非常非常非常非常非常非常长的标题超过二十个字了';
      final cleaned = UtilityModelService.cleanTitle(long);
      expect(cleaned, isNotNull);
      expect(cleaned!.length, lessThanOrEqualTo(21)); // 20 字 + 省略号
      expect(cleaned.endsWith('…'), isTrue);
    });

    test('空内容返回 null（调用方据此保留原标题）', () {
      expect(UtilityModelService.cleanTitle(''), isNull);
      expect(UtilityModelService.cleanTitle('   '), isNull);
      expect(UtilityModelService.cleanTitle('""'), isNull);
      expect(UtilityModelService.cleanTitle('标题：'), isNull);
      expect(UtilityModelService.cleanTitle('。'), isNull);
    });
  });
}
