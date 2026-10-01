# Tsukiro Chat —— Dart 命令包装
#
# 为什么需要包装：
#   本机在 DSH 沙箱下运行，Dart 默认会往工作区外写两处东西，会被拒绝：
#     - %APPDATA%\.dart-tool            （分析/遥测配置）
#     - %LOCALAPPDATA%\Pub\Cache        （pub 包缓存）
#   这里把它们重定向到仓库内的 .dart/ 目录，于是普通沙箱模式下也能工作。
#
# 用法:
#   pwsh -File scripts\dart.ps1 pub get
#   pwsh -File scripts\dart.ps1 analyze
#   pwsh -File scripts\dart.ps1 test
#   pwsh -File scripts\dart.ps1 test --reporter=expanded
#   pwsh -File scripts\dart.ps1 format .
#
# 注意: `dart analyze` 与 `dart test` 会启动 frontend_server / analysis_server
#       子进程并通过命名管道通信。DSH 沙箱的两种受限模式都不允许创建命名管道，
#       因此这两条命令需要一次性提权（danger-full-access）。
#       `dart pub get` / `dart format` / `dart run <单文件>` 不需要。

param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$DartArgs
)

$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $PSScriptRoot
$dartExe = 'C:\dev\dart-sdk\bin\dart.exe'

if (-not (Test-Path $dartExe)) {
  Write-Host "找不到 Dart SDK: $dartExe" -ForegroundColor Red
  Write-Host "先跑: node scripts\fetch-dart.mjs" -ForegroundColor Yellow
  exit 127
}

# 把 Dart 的家目录搬进仓库，避免写工作区外
$env:APPDATA = Join-Path $root '.dart\AppData\Roaming'
$env:LOCALAPPDATA = Join-Path $root '.dart\AppData\Local'
$env:PUB_CACHE = Join-Path $root '.dart\pub-cache'
foreach ($d in @($env:APPDATA, $env:LOCALAPPDATA, $env:PUB_CACHE)) {
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
}

& $dartExe @DartArgs
exit $LASTEXITCODE
