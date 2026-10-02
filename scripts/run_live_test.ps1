# 跑真实 API 测试。
#
# 不需要设任何环境变量 —— 配置从 dev/dev-config.json 读
# （首次使用：Copy-Item dev\dev-config.example.json dev\dev-config.json 然后填 apiKey）。
#
# 用法:
#   & .\scripts\run_live_test.ps1              # 跑全部
#   & .\scripts\run_live_test.ps1 -Filter "①"  # 只跑某一条
#   & .\scripts\run_live_test.ps1 -OfflineOnly # 顺带跑一遍离线测试

[CmdletBinding()]
param(
  [string]$Filter,
  [switch]$OfflineOnly,
  [switch]$WithOffline
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$pkgDir = Join-Path $repoRoot 'packages\model_gateway'
$configPath = Join-Path $repoRoot 'dev\dev-config.json'

if (-not (Test-Path $configPath)) {
  Write-Host "! 找不到 $configPath" -ForegroundColor Yellow
  Write-Host "  先执行: Copy-Item dev\dev-config.example.json dev\dev-config.json" -ForegroundColor Yellow
  Write-Host "  然后填入 apiKey，或改用环境变量 TSUKIRO_LIVE_BASE / TSUKIRO_LIVE_KEY" -ForegroundColor Yellow
}

Push-Location $pkgDir
try {
  if ($WithOffline -or $OfflineOnly) {
    Write-Host '=== 离线测试（不消耗 token） ===' -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'dart.ps1') test
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
  }

  if (-not $OfflineOnly) {
    Write-Host "`n=== 真实 API 测试（会消耗 token） ===" -ForegroundColor Cyan
    # 不要用 $args —— 那是 PowerShell 的自动变量，赋值会失败
    $dartArgs = @('test', 'test\live_api_test.dart', '--reporter=expanded')
    if ($Filter) { $dartArgs += @('--plain-name', $Filter) }
    & (Join-Path $PSScriptRoot 'dart.ps1') @dartArgs
    exit $LASTEXITCODE
  }
}
finally {
  Pop-Location
}
