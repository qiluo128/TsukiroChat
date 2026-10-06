/// Surface 注册表：统一管理 Web/Flame Surface 声明与实例边界。
library;

import '../manifest/manifest.dart';
import '../manifest/surface.dart';

class RegisteredSurface {
  const RegisteredSurface({
    required this.pluginId,
    required this.pluginVersion,
    required this.declaration,
  });

  final String pluginId;
  final String pluginVersion;
  final SurfaceDeclaration declaration;

  String get id => declaration.id;
  String get key => '$pluginId#$id';
}

class SurfaceRegistry {
  final Map<String, List<RegisteredSurface>> _byPlugin = <String, List<RegisteredSurface>>{};

  void registerPlugin(PluginManifest manifest) {
    unregisterPlugin(manifest.id);
    if (manifest.provides.surfaces.isEmpty) return;
    _byPlugin[manifest.id] = manifest.provides.surfaces
        .map((surface) => RegisteredSurface(
              pluginId: manifest.id,
              pluginVersion: manifest.version,
              declaration: surface,
            ))
        .toList(growable: false);
  }

  int unregisterPlugin(String pluginId) => _byPlugin.remove(pluginId)?.length ?? 0;

  List<RegisteredSurface> surfacesOf(String pluginId) =>
      List<RegisteredSurface>.unmodifiable(_byPlugin[pluginId] ?? const <RegisteredSurface>[]);

  RegisteredSurface? find(String pluginId, String surfaceId) {
    for (final surface in _byPlugin[pluginId] ?? const <RegisteredSurface>[]) {
      if (surface.id == surfaceId) return surface;
    }
    return null;
  }

  RegisteredSurface? findByGameType(String gameType) {
    for (final surfaces in _byPlugin.values) {
      for (final surface in surfaces) {
        if (surface.declaration.gameType == gameType) return surface;
      }
    }
    return null;
  }

  Iterable<RegisteredSurface> get all => _byPlugin.values.expand((items) => items);

  int get length => _byPlugin.values.fold(0, (sum, items) => sum + items.length);

  void clear() => _byPlugin.clear();
}
