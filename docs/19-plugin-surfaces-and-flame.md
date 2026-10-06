# 19 · Plugin Surface 与 Flame 架构

## 1. 目标与边界

Tsukiro Chat 需要支持拖拽、图标、自定义输入、富文本、动画和小游戏，但插件不能因此获得宿主级 Dart/Flutter 执行权。本项目采用三层 UI：

| 层 | 内容 | 信任级别 |
|---|---|---|
| L1 Native UI | `provides.ui` 的 button、toggle、section、text 等，由 Flutter 宿主渲染 | 低信任插件 |
| L2 Interactive Web Surface | 插件自己的 HTML/CSS/JS WebView，可用 DOM、富文本、拖拽、CSS 动画、Canvas | 低信任插件 |
| L3 Trusted Flame Surface | 宿主编译期注册的 `FlameGame` 工厂，由 manifest 选择 `gameType` | 受信任宿主扩展 |

普通插件包只允许 `manifest.json`、JS、HTML 和静态资源，**不能携带或动态执行 Dart/Flutter/native runtime**。Flame 代码放在 `packages/host_app` 的受信任代码中；第三方若未来需要自带 Flame 代码，必须另立签名 Trusted Extension 分发模型。

所有宿主能力仍遵循：

```text
Surface / Worker → Bridge → Gatekeeper → PrimitiveRegistry → Host API
```

Surface 的视觉自由度不等于系统权限。`richText`、`animation` 是 UI capability；文件、网络、模型、剪贴板仍需独立 permission。

## 2. Surface Manifest

在 `provides` 下增加可选的 `surfaces`：

```json
{
  "provides": {
    "surfaces": [
      {
        "id": "game",
        "kind": "flame",
        "slot": "agent.sections",
        "gameType": "demo.guess_number",
        "presentation": "fullscreen",
        "minWidth": 320,
        "minHeight": 240,
        "maxWidth": 720,
        "maxHeight": 900,
        "capabilities": ["interaction", "animation"],
        "permissions": ["ui", "model.chat"]
      },
      {
        "id": "editor",
        "kind": "web",
        "slot": "agent.sections",
        "entry": "surfaces/editor.html",
        "capabilities": ["interaction", "dragDrop", "richText", "animation"],
        "permissions": ["ui.surface", "ui.dragDrop"]
      }
    ]
  }
}
```

`kind` 只有 `web` 和 `flame`。`web` 必须有插件包内 `entry`；`flame` 必须有宿主注册的 `gameType`。未知 capability 被记录为 warning，不得自动变成系统权限。

Surface 绑定插件实例和 Surface 实例：

```text
pluginId + pluginVersion + instanceId + surfaceId
```

重装、停用、卸载时，旧 Surface 必须销毁，旧实例消息必须被拒绝。

## 3. L2 Interactive Web Surface

Web Surface 使用独立 WebView，只能控制自身 DOM。宿主控制：

- CSP：默认禁止外部连接；网络必须走 `tsukiro.net.*`；
- 导航：禁止外部导航和 iframe；
- 尺寸：Surface 有最小/最大宽高和 resize 预算；
- 生命周期：`ready`、`resize`、`visibility`、`destroy`；
- 文件：拖拽返回不透明 file handle，不暴露绝对路径；
- 富文本：插件自己的 Surface 可自由编辑；写入宿主消息时必须使用白名单 Rich Content AST；
- 图标：插件资源只允许包内 PNG/SVG，SVG 清除 script/foreignObject/事件属性；
- 动画：页面不可见时暂停，Canvas/WebGL 需要显式 capability。

L2 不允许：直接访问 Flutter context、Navigator、SQLite、API Key、宿主 DOM 或未声明原语。

## 4. L3 Trusted Flame Surface

Flame 依赖只加入 `packages/host_app`。宿主维护：

```text
FlameGameFactory: gameType → FlameGame
```

manifest 只能选择已注册的 `gameType`，不能上传 Dart 代码。`GameWidget` 由宿主创建并挂载在受控 `PluginSurfaceHost` 中。宿主负责：

- 创建/暂停/恢复/销毁游戏实例；
- 将 Surface 输入和 Bridge 事件转成游戏事件；
- 限制资源、尺寸和实例数；
- 插件停用/重装时销毁旧游戏；
- 游戏需要模型、文件、网络时仍通过 Bridge/权限。

## 5. Bridge Surface 事件

在现有 Bridge 事件模型上定义：

```text
surface.ready
surface.resize
surface.visibility
surface.input
surface.destroy
```

消息必须携带 `instanceId` 和 `surfaceId`。Surface 请求沿用现有大小限制、pending 上限、超时、权限校验和审计。Surface 不创建第二套权限系统。

## 6. 测试分层

1. `plugin_core`：manifest/parser、SurfaceRegistry、capability/permission 分离、实例绑定、卸载清理。
2. host_app widget：Web Surface CSP/导航/resize/destroy，Flame factory/GameWidget 生命周期，未注册 gameType 返回 `UNSUPPORTED`。
3. JS contract：fake Bridge 验证点击、dialog、model、Surface 事件和异常。
4. Android 集成：真实 WebView handshake、Surface 加载、拖拽、输入、动画、Flame 页面切换和重装。

真实 API 测试与插件 Surface 测试分离；Surface 测试使用 fake gateway/fake Bridge，不依赖网络。

## 7. 兼容与发布

`provides.surfaces` 是可选字段，旧宿主忽略；声明 Flame 但宿主没有对应 `gameType` 时，Surface 显示明确 `UNSUPPORTED`，不能假装加载。普通插件的 Zip 检查继续拒绝 native binary、Dart snapshot、APK、JAR 等运行时载荷。
