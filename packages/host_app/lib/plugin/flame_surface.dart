/// 受信任宿主 Flame Surface。
///
/// 普通插件只声明 gameType，不能上传 Dart/Flutter 代码；真正的 FlameGame
/// 必须由宿主编译期注册到 [FlameGameRegistry]。
library;

import 'dart:async';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';

import 'plugin_host.dart';

/// 宿主内置 Flame 游戏工厂。
typedef FlameGameFactory = FlameGame Function({Map<String, dynamic>? params});

class FlameGameRegistry {
  final Map<String, FlameGameFactory> _factories = <String, FlameGameFactory>{};

  void register(String gameType, FlameGameFactory factory) {
    if (gameType.trim().isEmpty) throw ArgumentError.value(gameType, 'gameType');
    _factories[gameType] = factory;
  }

  FlameGame? create(String gameType, {Map<String, dynamic>? params}) =>
      _factories[gameType]?.call(params: params);

  bool contains(String gameType) => _factories.containsKey(gameType);

  Set<String> get gameTypes => _factories.keys.toSet();
}

/// 一个极小的宿主示例游戏，用于验证 GameWidget 生命周期和 Surface 边界。
class PluginSceneGame extends FlameGame {
  PluginSceneGame({this.onEvent, Map<String, dynamic>? initialState}) {
    state = initialState ?? <String, dynamic>{};
  }

  void Function(Map<String, dynamic> event)? onEvent;
  late Map<String, dynamic> state;
  final List<Component> _rendered = <Component>[];

  @override
  Future<void> onLoad() async {
    await _render();
  }

  Future<void> updateState(Map<String, dynamic> next) async {
    state = Map<String, dynamic>.from(next);
    await _render();
  }

  Future<void> _render() async {
    for (final component in _rendered) {
      component.removeFromParent();
    }
    _rendered.clear();
    final title = state['title']?.toString() ?? 'Surface';
    final score = state['score']?.toString() ?? '';
    final result = state['result']?.toString() ?? '';
    final header = TextComponent(
      text: '$title\\n$score\\n$result',
      position: Vector2(16, 16),
      textRenderer: TextPaint(style: const TextStyle(color: Colors.white, fontSize: 18)),
    );
    await add(header);
    _rendered.add(header);
    final buttons = state['buttons'];
    if (buttons is List) {
      var index = 0;
      for (final item in buttons.whereType<Map>()) {
        final id = item['id']?.toString() ?? '';
        final label = item['label']?.toString() ?? id;
        final button = _SceneButton(
          position: Vector2(16 + index * 105, 150),
          size: Vector2(95, 48),
          onPressed: () => onEvent?.call(<String, dynamic>{'action': 'choice', 'value': id}),
        );
        await add(button);
        final buttonLabel = TextComponent(
          text: label,
          position: Vector2(32 + index * 105, 165),
          textRenderer: TextPaint(style: const TextStyle(color: Colors.white, fontSize: 14)),
        );
        await add(buttonLabel);
        _rendered.add(button);
        _rendered.add(buttonLabel);
        index++;
      }
    }

    final actions = state['actions'];
    if (actions is List) {
      var index = 0;
      for (final item in actions.whereType<Map>()) {
        final id = item['id']?.toString() ?? '';
        final label = item['label']?.toString() ?? id;
        final button = _SceneButton(
          position: Vector2(16 + index * 120, 230),
          size: Vector2(110, 42),
          onPressed: () => onEvent?.call(<String, dynamic>{'action': id}),
        );
        final buttonLabel = TextComponent(
          text: label,
          position: Vector2(30 + index * 120, 243),
          textRenderer: TextPaint(style: const TextStyle(color: Colors.white, fontSize: 13)),
        );
        await add(button);
        await add(buttonLabel);
        _rendered.add(button);
        _rendered.add(buttonLabel);
        index++;
      }
    }
  }
}

class _SceneButton extends PositionComponent with TapCallbacks {
  _SceneButton({required super.position, required super.size, required this.onPressed});

  final VoidCallback onPressed;

  @override
  void onTapUp(TapUpEvent event) => onPressed();

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    canvas.drawRect(size.toRect(), Paint()..color = Colors.indigo);
  }
}

class DemoSurfaceGame extends FlameGame {
  DemoSurfaceGame({this.label = 'Flame Surface'});

  final String label;

  @override
  Future<void> onLoad() async {
    await add(TextComponent(
      text: label,
      position: Vector2(16, 16),
      textRenderer: TextPaint(
        style: const TextStyle(color: Colors.white, fontSize: 18),
      ),
    ));
  }
}

/// 根据已注册 Surface 声明挂载 Flame GameWidget。
class PluginFlameSurface extends StatefulWidget {
  const PluginFlameSurface({
    super.key,
    required this.host,
    required this.pluginId,
    required this.surfaceId,
    this.params,
    this.onCreated,
    this.onEvent,
  });

  final PluginHost host;
  final String pluginId;
  final String surfaceId;
  final Map<String, dynamic>? params;
  final void Function(FlameGame game)? onCreated;
  final void Function(Map<String, dynamic> event)? onEvent;

  @override
  State<PluginFlameSurface> createState() => _PluginFlameSurfaceState();
}

class _PluginFlameSurfaceState extends State<PluginFlameSurface> {
  FlameGame? _game;
  String? _error;

  @override
  void initState() {
    super.initState();
    _create();
  }

  void _create() {
    final surface = widget.host.surfaceRegistry.find(widget.pluginId, widget.surfaceId);
    if (surface == null || !surface.declaration.isFlame) {
      _error = '找不到 Flame Surface ${widget.pluginId}#${widget.surfaceId}';
      return;
    }
    final gameType = surface.declaration.gameType;
    if (gameType == null) {
      _error = 'Flame Surface 没有 gameType';
      return;
    }
    final game = flameGameRegistry.create(gameType, params: widget.params);
    if (game == null) {
      _error = '宿主不支持 Flame gameType: $gameType';
      return;
    }
    if (game is PluginSceneGame) game.onEvent = widget.onEvent;
    _game = game;
    widget.onCreated?.call(game);
  }

  @override
  void dispose() {
    // GameWidget 会在 widget 销毁时停止渲染；不保存跨 Surface 的全局游戏实例。
    _game = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final game = _game;
    if (game == null) {
      return ColoredBox(
        color: Colors.black87,
        child: Center(child: Text(_error ?? 'Flame Surface 不可用')),
      );
    }
    return GameWidget(game: game);
  }
}

final FlameGameRegistry flameGameRegistry = FlameGameRegistry()
  ..register('demo.surface', ({params}) => DemoSurfaceGame(
        label: params?['label']?.toString() ?? 'Flame Surface',
      ))
  ..register('plugin.scene', ({params}) => PluginSceneGame(
        initialState: params,
      ));
