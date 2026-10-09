/// 用户选的图片落盘。
///
/// ## 为什么必须复制一份
///
/// `image_picker` 给的是**临时目录**里的路径。系统随时会清缓存 ——
/// 用户今天选的头像，下周打开应用就变成破图了。
///
/// 所以选完立刻复制进应用私有目录，之后只引用我们自己的那份。
///
/// 这也顺带解决了一件事：**插件永远拿不到用户相册的路径** ——
/// 它看到的只是应用私有目录里的一个文件，而那个目录插件进不去
/// （沙箱根是插件的独立目录）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class MediaStore {
  MediaStore(this._docs);

  final Directory _docs;

  /// 应用启动时构造一次。
  static Future<MediaStore> open() async =>
      MediaStore(await getApplicationDocumentsDirectory());

  Directory get _avatarDir => Directory(p.join(_docs.path, 'avatars'));
  Directory get _backgroundDir => Directory(p.join(_docs.path, 'backgrounds'));

  /// 把一张图存成智能体头像（每个智能体一份，同名覆盖）。
  ///
  /// 返回可直接写进 `Agent.avatarPath` 的值。
  Future<String> saveAvatar({
    required String agentId,
    required String sourcePath,
  }) async {
    final dir = _avatarDir;
    await dir.create(recursive: true);
    // 文件名用 agentId（不含用户输入）—— 避免路径注入，
    // 也顺便让"每个智能体一个头像"这件事在磁盘上看得见
    final ext = _safeExtension(sourcePath);
    final target = p.join(dir.path, '$agentId$ext');
    await _copyReplacing(sourcePath, target);
    // 换扩展名时清掉旧的，不然会留下孤儿文件
    await _removeSiblings(dir, agentId, keep: target);
    return target;
  }

  /// 存一张聊天背景图。返回可直接写进设置的路径。
  Future<String> saveBackground({required String sourcePath}) async {
    final dir = _backgroundDir;
    await dir.create(recursive: true);
    final ext = _safeExtension(sourcePath);
    // 单张背景：固定名，选新的就覆盖
    final target = p.join(dir.path, 'chat$ext');
    await _copyReplacing(sourcePath, target);
    await _removeSiblings(dir, 'chat', keep: target);
    return target;
  }

  /// 删掉某个智能体的头像文件（用户点"恢复默认"时）。
  Future<void> deleteAvatar(String agentId) async {
    final dir = _avatarDir;
    if (!dir.existsSync()) return;
    await _removeSiblings(dir, agentId, keep: null);
  }

  Future<void> deleteBackground() async {
    final dir = _backgroundDir;
    if (!dir.existsSync()) return;
    await _removeSiblings(dir, 'chat', keep: null);
  }

  // ─────────────────────────── 内部 ───────────────────────────

  /// 只接受一小撮扩展名。
  ///
  /// **不接受任意扩展名**：`image_picker` 理论上只给图片，但
  /// 直接拿用户可控的字符串拼文件名是没必要冒的险。
  static String _safeExtension(String sourcePath) {
    final ext = p.extension(sourcePath).toLowerCase();
    const allowed = <String>{'.png', '.jpg', '.jpeg', '.webp', '.gif', '.heic'};
    return allowed.contains(ext) ? ext : '.png';
  }

  Future<void> _copyReplacing(String source, String target) async {
    final src = File(source);
    if (!src.existsSync()) {
      throw FileSystemException('选中的图片已不存在', source);
    }
    // 先写临时文件再 rename：中途失败不会留下半张图，
    // 而半张图会让界面显示一个坏掉的头像
    final tmp = File('$target.tmp');
    await src.copy(tmp.path);
    if (File(target).existsSync()) await File(target).delete();
    await tmp.rename(target);
  }

  /// 清掉同一个基名下的其它扩展名文件。
  Future<void> _removeSiblings(Directory dir, String base, {String? keep}) async {
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basenameWithoutExtension(entity.path);
      if (name != base) continue;
      if (keep != null && p.equals(entity.path, keep)) continue;
      try {
        await entity.delete();
      } catch (_) {
        // 删不掉就留着 —— 一个孤儿文件不值得让操作失败
      }
    }
  }
}
