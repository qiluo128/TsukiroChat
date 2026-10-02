# dev/ —— 本地开发配置

这里放**不进版本控制**的本地开发配置。

## 为什么单独一个目录

`dev-config.json` 里有真实的 API Key。仓库是 public 的，直接提交等于：
1. GitHub 密钥扫描会在几分钟内标记它（可能自动吊销）
2. 爬虫持续扫 GitHub，捞到就会消耗你的额度
3. **即使以后删掉，git 历史里还在** —— 删文件不等于删密钥

所以真实配置放这里（gitignore 掉），仓库里只提交 `dev-config.example.json` 模板。

## 怎么用

```powershell
# 首次：从模板创建
Copy-Item dev\dev-config.example.json dev\dev-config.json
# 然后填 apiKey

# 之后直接跑，不用设任何环境变量
& .\scripts\run_live_test.ps1
```

优先级：**环境变量 > dev-config.json**。想在 CI 上用不同的 key，设环境变量即可覆盖，不必改文件。

## Android 侧复用

同一份 JSON 可以直接放进 Flutter 工程的 assets：

```
packages/host_app/assets/dev-config.json     ← 复制 dev/dev-config.json
pubspec.yaml:
  assets:
    - assets/dev-config.json
```

运行时：

```dart
final raw = await rootBundle.loadString('assets/dev-config.json');
final config = ProviderConfig.fromJson(jsonDecode(raw)['provider']);
```

⚠️ **打包发给用户时务必去掉这个 asset。** 正式版走网关（用户 Token），
客户端不该带任何上游 Key —— 这是设计红线（见 `docs/01-overview.md` §3 原则 4）。

## 文件清单

| 文件 | 是否提交 | 说明 |
|---|---|---|
| `dev-config.example.json` | ✅ 提交 | 模板，含字段说明与候选模型 |
| `dev-config.json` | ❌ 忽略 | 真实配置 |
