/// Tsukiro Chat 插件内核。
///
/// **纯 Dart，无 Flutter 依赖** —— 这是刻意的约束（见 ADR-002）：
/// 插件系统的技术风险（manifest 校验、权限守门、Bridge 编解码、Zip Slip 防护、
/// 工具循环、钩子调度）全部是纯逻辑，能在桌面用 `dart test` 测透，就不必在
/// 「Flutter + Android + WebView + JS + Dart」五层里混合调试。
///
/// ## 三条扩展性主线（见 `docs/16-extensibility.md`）
///
/// | 轴 | 做法 | 入口 |
/// |---|---|---|
/// | 能力 | 原语是**数据**，加原语 = `registry.register(spec)` | [PrimitiveRegistry] |
/// | 时机 | 钩子是**公开相位**，加时机 = 加枚举项 + 宿主 `emit` | [HookBus] |
/// | 位置 | 插槽是**字符串**，加位置 = UI 里多挂一个 `SlotHost` | `SlotRegistry`（待做） |
///
/// ## 用法概览
///
/// ```dart
/// // 1) 装配宿主服务（无头测试用假实现，Flutter 宿主用真实现）
/// final services = ServiceRegistry()
///   ..put<HostClock>(FakeClock())
///   ..put<HostUi>(RecordingUi())
///   ..put<HostFiles>(InMemoryFiles())
///   ..put<SandboxProvider>(FakeSandbox())
///   ..put<ModelGateway>(ScriptedGateway());
///
/// // 2) 建注册表：全部 24 个域都注册，只有 4 个有真实现
/// final gk = Gatekeeper();
/// final registry = PrimitiveRegistry(gatekeeper: gk, services: services);
/// registry.registerAll(standardPrimitiveCatalog(implemented: demoPrimitiveHandlers));
/// services.put<PrimitiveRegistry>(registry);   // 供自省原语使用
///
/// // 3) 调原语（权限、参数、超时、审计全在这一条路径上）
/// final t = await registry.invoke('dev.tsukiro.time', 'sys.time', {'tz': 'Asia/Shanghai'});
/// ```
library;

// ── 基础设施 ──
export 'src/agent/chat_message.dart';
export 'src/audit/audit.dart';
export 'src/common/cancellation.dart';
export 'src/common/errors.dart';
export 'src/common/semver.dart';

// ── 插件描述与包 ──
export 'src/manifest/manifest.dart';
export 'src/manifest/parser.dart';
export 'src/packaging/installer.dart';
export 'src/packaging/package_inspector.dart';
export 'src/packaging/zip_reader.dart';

// ── 权限 ──
export 'src/permission/gatekeeper.dart';
export 'src/permission/permission.dart';

// ── 宿主侧实现参考（纯 Dart，可在无头环境跑） ──
export 'src/host/in_memory_services.dart';

// ── 能力轴 ──
export 'src/primitive/demo_primitives.dart';
export 'src/primitive/host_services.dart';
export 'src/primitive/primitive_catalog.dart';
export 'src/primitive/primitive_registry.dart';
export 'src/primitive/primitive_spec.dart';
export 'src/primitive/schema_validator.dart';
export 'src/primitive/service_registry.dart';

// ── 时机轴 ──
export 'src/hook/hook_bus.dart';

// ── 注册表 ──
export 'src/registry/slot_registry.dart';
export 'src/registry/tool_registry.dart';

// ── 沙箱 ──
export 'src/sandbox/path_guard.dart';

// ── 传输 ──
export 'src/bridge/envelope.dart';
export 'src/bridge/session.dart';
