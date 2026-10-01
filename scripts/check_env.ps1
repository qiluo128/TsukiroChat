# Tsukiro Chat 环境自检
#
# 用法:  & .\scripts\check_env.ps1
#        （本机只装了 Windows PowerShell，不要用 pwsh -File）
#
# 只读脚本，不修改任何东西。沙箱下部分系统查询会被拒（已容错处理）。

$ErrorActionPreference = 'Continue'

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($m)      { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Miss($m)    { Write-Host "  [--]   $m" -ForegroundColor DarkGray }
function Warn($m)    { Write-Host "  [!!]   $m" -ForegroundColor Yellow }

$repoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "Tsukiro Chat - 开发环境自检" -ForegroundColor White
Write-Host "仓库: $repoRoot"

# ── 基础工具 ──────────────────────────────────────────────
Section '基础工具链'
foreach ($t in @(
  @{ n = 'git';    c = 'git';    a = @('--version') },
  @{ n = 'node';   c = 'node';   a = @('--version') },
  @{ n = 'python'; c = 'python'; a = @('--version') }
)) {
  $cmd = Get-Command $t.c -ErrorAction SilentlyContinue
  if ($cmd) { Ok ("{0,-7}: {1}" -f $t.n, ((& $t.c @($t.a) 2>&1 | Select-Object -First 1))) }
  else      { Miss "$($t.n) : 未安装" }
}

# ── C:\dev 工具链 ─────────────────────────────────────────
Section 'C:\dev 工具链'

$dart = 'C:\dev\dart-sdk\bin\dart.exe'
if (Test-Path $dart) {
  Ok "Dart SDK  : $(& $dart --version 2>&1)"
} else {
  Miss 'Dart SDK  : 未安装'
  Write-Host '             → node scripts\fetch-dart.mjs  然后解压到 C:\dev\dart-sdk' -ForegroundColor DarkGray
}

$flutter = 'C:\dev\flutter\bin\flutter.bat'
if (Test-Path $flutter) {
  Ok "Flutter   : $(& $flutter --version 2>&1 | Select-Object -First 1)"
} else {
  Miss 'Flutter   : 未安装（Flutter 宿主阶段才需要，约 1 GB）'
}

if ($env:JAVA_HOME -and (Test-Path $env:JAVA_HOME)) {
  Ok "JAVA_HOME : $env:JAVA_HOME"
} elseif (Test-Path 'C:\dev\jdk\bin\java.exe') {
  Warn 'JDK 在 C:\dev\jdk 但 JAVA_HOME 未设置'
} else {
  Miss 'JDK 17    : 未安装（约 200 MB）'
}

if ($env:ANDROID_HOME -and (Test-Path $env:ANDROID_HOME)) {
  Ok "ANDROID_HOME: $env:ANDROID_HOME"
  $adb = Join-Path $env:ANDROID_HOME 'platform-tools\adb.exe'
  if (Test-Path $adb) {
    $devices = (& $adb devices 2>&1 | Select-Object -Skip 1 | Where-Object { $_ -match '\S' })
    if ($devices) { Ok "adb 设备:`n$(($devices | ForEach-Object { "             $_" }) -join "`n")" }
    else          { Warn 'adb 已装，但没有连接设备（建议用真机而非模拟器）' }
  } else { Warn 'adb 未找到（platform-tools 未安装）' }
} else {
  Miss 'Android SDK: 未安装（约 3–5 GB，需 C 盘可用 >= 15 GB）'
}

# ── 仓库结构 ──────────────────────────────────────────────
Section '仓库结构'
foreach ($e in @('docs', 'packages\plugin_core', 'plugins', 'scripts', '.gitignore')) {
  if (Test-Path (Join-Path $repoRoot $e)) { Ok $e } else { Warn "缺少: $e" }
}

$docs = Get-ChildItem (Join-Path $repoRoot 'docs') -Filter '*.md' -ErrorAction SilentlyContinue
if ($docs) { Ok "docs/ 下 $($docs.Count) 篇文档" } else { Warn 'docs/ 为空' }

$plugins = Get-ChildItem (Join-Path $repoRoot 'plugins') -Directory -ErrorAction SilentlyContinue
if ($plugins) { Ok "plugins/ 下 $($plugins.Count) 个插件：$($plugins.Name -join ', ')" }
else { Warn 'plugins/ 为空' }

# ── plugin_core 状态 ──────────────────────────────────────
Section 'plugin_core 状态'
$pc = Join-Path $repoRoot 'packages\plugin_core'
$tests = Get-ChildItem (Join-Path $pc 'test') -Filter '*_test.dart' -ErrorAction SilentlyContinue
if ($tests) { Ok "$($tests.Count) 个测试文件" } else { Warn '没有测试文件' }

$pubspecLock = Join-Path $pc 'pubspec.lock'
if (Test-Path $pubspecLock) { Ok 'pubspec.lock 存在（依赖已解析，可跳过 pub get）' }
else { Warn 'pubspec.lock 不存在 → 先跑 & .\scripts\dart.ps1 pub get' }

# ── 沙箱注意事项 ──────────────────────────────────────────
Section '沙箱注意事项'

try {
  $null = Get-Volume -ErrorAction Stop
  Ok 'Get-Volume 可用（未受限）'
} catch {
  Warn 'Get-Volume 被拒 —— 无法读取磁盘剩余空间，装 Flutter/Android SDK 前请手工确认 C 盘 >= 15 GB'
}

# curl 的 TLS 在沙箱下不可用
$curlOk = $false
try {
  $r = & curl.exe -s -o NUL -w '%{http_code}' --max-time 8 https://pub.dev 2>$null
  if ($r -eq '200') { $curlOk = $true }
} catch { }
if ($curlOk) { Ok 'curl TLS 可用' }
else { Warn 'curl/pwsh TLS 不可用（SEC_E_NO_CREDENTIALS）→ 请用 node/python 下载' }

# Node TLS（用独立脚本而不是 node -e，避免 PowerShell 引号地狱）
$nodeOk = $false
$probe = Join-Path $PSScriptRoot 'tls_probe.mjs'
if (Test-Path $probe) {
  $out = & node $probe https://pub.dev 2>&1
  if ("$out" -match '^OK 200') { $nodeOk = $true }
}
if ($nodeOk) { Ok 'Node TLS 可用 → 可用 scripts/fetch-dart.mjs 下载' }
else { Warn 'Node TLS 也不可用，请检查网络' }

# Dart 家目录是否已被重定向（.dart/ 应存在）
if (Test-Path (Join-Path $repoRoot '.dart\pub-cache')) {
  Ok '.dart/pub-cache 存在（Dart 家目录已重定向进仓库）'
} else {
  Warn '.dart/pub-cache 不存在 → 用 & .\scripts\dart.ps1 而不是直接调 dart.exe'
}

# ── 下一步建议 ────────────────────────────────────────────
Section '下一步'
if (-not (Test-Path $dart)) {
  Write-Host '  1) node scripts\fetch-dart.mjs' -ForegroundColor White
  Write-Host '  2) 解压到 C:\dev\dart-sdk（需提权，步骤见 docs/13-dev-environment.md §3.1）' -ForegroundColor White
} elseif (-not (Test-Path $pubspecLock)) {
  Write-Host '  & .\scripts\dart.ps1 pub get     # 不需要提权' -ForegroundColor White
} else {
  Write-Host '  内核已就绪。验证：' -ForegroundColor White
  Write-Host '    & .\scripts\dart.ps1 analyze   # 需提权 → 期望 No issues found!' -ForegroundColor White
  Write-Host '    & .\scripts\dart.ps1 test      # 需提权 → 期望 All tests passed! (169)' -ForegroundColor White
  Write-Host ''
  Write-Host '  下一步开发任务见 docs/15-status.md §4' -ForegroundColor White
}

Write-Host ''
