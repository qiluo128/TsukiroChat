# 把构建好的 APK 装到手机。
#
# 用法:
#   & .\scripts\install_apk.ps1              # 有设备就装，没有就导出到桌面
#   & .\scripts\install_apk.ps1 -Release     # 明确装 release 版（默认）
#   & .\scripts\install_apk.ps1 -DebugBuild  # 装 debug 版
#   & .\scripts\install_apk.ps1 -Uninstall   # 先卸载再装（签名变了时必须）
#
# 为什么值得有个脚本：真机调试会反复装，手敲 adb 路径 + 找 APK 路径很烦。
# 另外「没有设备时自动导出到桌面」这个分支，比让你自己去 build 目录里翻要省事。

[CmdletBinding()]
param(
  # 不能叫 -Debug —— 那是 PowerShell 的通用参数，会冲突
  [switch]$DebugBuild,
  [switch]$Uninstall
)

$ErrorActionPreference = 'Continue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$adb = 'C:\dev\android-sdk\platform-tools\adb.exe'
$apkDir = Join-Path $repoRoot 'packages\host_app\build\app\outputs\flutter-apk'
$apkName = if ($DebugBuild) { 'app-debug.apk' } else { 'app-release.apk' }
$apk = Join-Path $apkDir $apkName

# 外部命令的 stderr 不该被当成错误（flutter/adb 都爱往 stderr 写正常输出）
function Invoke-Native {
  param([string]$Exe, [string[]]$Arguments = @(), [int]$Tail = 8)
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $out | Select-Object -Last $Tail | ForEach-Object { Write-Host "    $_" }
    return $code
  } finally {
    $ErrorActionPreference = $saved
  }
}

if (-not (Test-Path $apk)) {
  Write-Host "✗ 找不到 $apkName" -ForegroundColor Red
  Write-Host '  先构建：' -ForegroundColor Yellow
  Write-Host '    cd packages\host_app' -ForegroundColor Yellow
  Write-Host "    & C:\dev\flutter\bin\flutter.bat build apk $($(if ($DebugBuild) { '--debug' } else { '--release' }))" -ForegroundColor Yellow
  exit 1
}

$size = (Get-Item $apk).Length / 1MB
Write-Host "APK: $apkName  ($([math]::Round($size,1)) MB)" -ForegroundColor Cyan

# ── 找设备 ──
$devices = @()
if (Test-Path $adb) {
  $raw = & $adb devices 2>&1
  $devices = @($raw | Select-Object -Skip 1 | Where-Object { $_ -match '\tdevice$' })
}

if ($devices.Count -eq 0) {
  Write-Host "`n没有检测到设备。三种装法：" -ForegroundColor Yellow
  Write-Host ''
  Write-Host '  ① USB 调试（推荐，能看日志）' -ForegroundColor White
  Write-Host '     手机：设置 → 关于手机 → 连点「版本号」7 次 → 开发者选项 → USB 调试'
  Write-Host '     插上数据线 → 手机上允许调试 → 重跑这个脚本'
  Write-Host ''
  Write-Host '  ② 直接传文件（不用数据线）' -ForegroundColor White
  Write-Host '     把下面这个文件发到手机（微信/QQ/网盘都行），点开安装'
  Write-Host '     手机需允许「安装未知来源应用」'
  $desktop = [Environment]::GetFolderPath('Desktop')
  $dest = Join-Path $desktop $apkName
  Copy-Item $apk $dest -Force
  Write-Host "     已复制到：$dest" -ForegroundColor Green
  Write-Host ''
  Write-Host '  ③ 无线调试（Android 11+）' -ForegroundColor White
  Write-Host '     手机：开发者选项 → 无线调试 → 使用配对码配对'
  Write-Host '     & adb pair <手机IP>:<配对端口>'
  Write-Host '     & adb connect <手机IP>:<调试端口>'
  Write-Host '     然后重跑这个脚本'
  return
}

Write-Host "`n检测到 $($devices.Count) 个设备：" -ForegroundColor Green
$devices | ForEach-Object { Write-Host "  $_" }

if ($Uninstall) {
  Write-Host "`n先卸载旧版本（签名变过时必须这么做，否则会 INSTALL_FAILED_UPDATE_INCOMPATIBLE）"
  Invoke-Native $adb @('uninstall', 'dev.tsukiro.tsukiro_chat') | Out-Null
}

Write-Host "`n安装中…"
$code = Invoke-Native $adb @('install', '-r', '-d', $apk)

if ($code -eq 0) {
  Write-Host "`n✓ 安装成功" -ForegroundColor Green
  Write-Host '  手机上找「Tsukiro Chat」图标。' -ForegroundColor White
  Write-Host ''
  Write-Host '  看日志（排查崩溃很关键）：' -ForegroundColor DarkGray
  Write-Host '    & C:\dev\android-sdk\platform-tools\adb.exe logcat -s flutter' -ForegroundColor DarkGray
} else {
  Write-Host "`n✗ 安装失败（exit $code）" -ForegroundColor Red
  Write-Host '  常见原因：' -ForegroundColor Yellow
  Write-Host '    INSTALL_FAILED_UPDATE_INCOMPATIBLE → 签名不同，加 -Uninstall 重装'
  Write-Host '    INSTALL_FAILED_VERSION_DOWNGRADE   → 已装更高版本，先卸载'
  Write-Host '    INSTALL_FAILED_USER_RESTRICTED     → 手机上要允许「USB 安装」'
  Write-Host '    设备未授权                          → 手机上点「允许 USB 调试」'
}
