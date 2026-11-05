# 模拟器测试环境
#
# 为什么需要它：这个项目一直是「我改代码 → 你装机 → 你报现象 → 我猜」。
# 那个循环里我**看不到任何证据**，所以 MCP 那轮猜了五次、定位崩溃猜了两次。
#
# 有了模拟器，我能自己装、自己点、自己看日志。慢的那部分（人）被拿掉了。
#
# 用法：
#   .\scripts\emu.ps1 boot            # 启动（已在跑就不重启）
#   .\scripts\emu.ps1 install         # 装当前 APK
#   .\scripts\emu.ps1 taps "新建智能体"  # 按语义标签点击（不用猜坐标）
#   .\scripts\emu.ps1 ui              # 列出当前界面的所有标签
#   .\scripts\emu.ps1 shot            # 截图到 dev\shot.png
#   .\scripts\emu.ps1 logs            # 最近的 flutter + 崩溃日志
#
# 首次搭建（已完成，记下来免得忘）：
#   sdkmanager --install "emulator" "system-images;android-35;google_apis;x86_64"
#   avdmanager create avd -n tsukiro -k "system-images;android-35;google_apis;x86_64" -d pixel_6

param(
  [Parameter(Position = 0)][string]$Command = 'help',
  [Parameter(Position = 1)][string]$Arg1,
  [Parameter(Position = 2)][string]$Arg2
)

$ErrorActionPreference = 'Continue'
$sdk = 'C:\dev\android-sdk'
$adb = Join-Path $sdk 'platform-tools\adb.exe'
$emu = Join-Path $sdk 'emulator\emulator.exe'
$pkg = 'dev.tsukiro.tsukiro_chat'
$apk = Join-Path $PSScriptRoot '..\packages\host_app\build\app\outputs\flutter-apk\app-release.apk'
$devDir = Join-Path $PSScriptRoot '..\dev'

function Get-Device {
  $d = & $adb devices 2>&1 | Select-String 'emulator-\d+\s+device'
  if ($d) { return ($d -split '\s+')[0] }
  return $null
}

function Invoke-Dump {
  & $adb shell uiautomator dump /sdcard/ui.xml 2>&1 | Out-Null
  $tmp = Join-Path $devDir 'ui.xml'
  & $adb pull /sdcard/ui.xml $tmp 2>&1 | Out-Null
  if (-not (Test-Path $tmp)) { return $null }
  return [System.IO.File]::ReadAllText($tmp, [System.Text.Encoding]::UTF8)
}

function Get-Nodes {
  param([string]$Xml)
  $out = @()
  foreach ($n in [regex]::Matches($Xml, '<node[^>]*/>')) {
    $t = [regex]::Match($n.Value, 'text="([^"]*)"').Groups[1].Value
    $d = [regex]::Match($n.Value, 'content-desc="([^"]*)"').Groups[1].Value
    $label = if ($d) { $d } else { $t }
    if ($label -eq '') { continue }
    $b = [regex]::Match($n.Value, 'bounds="\[(\d+),(\d+)\]\[(\d+),(\d+)\]"')
    if (-not $b.Success) { continue }
    $out += [pscustomobject]@{
      Label = ($label -replace '&#10;', ' | ')
      X     = [int]([int]$b.Groups[1].Value + ([int]$b.Groups[3].Value - [int]$b.Groups[1].Value) / 2)
      Y     = [int]([int]$b.Groups[2].Value + ([int]$b.Groups[4].Value - [int]$b.Groups[2].Value) / 2)
    }
  }
  return $out
}

New-Item -ItemType Directory -Force -Path $devDir | Out-Null

switch ($Command) {
  'boot' {
    if (Get-Device) { Write-Output '  模拟器已在运行'; break }
    Start-Process -FilePath $emu -ArgumentList @('-avd', 'tsukiro', '-no-window', '-no-audio', '-no-boot-anim', '-no-snapshot', '-gpu', 'swiftshader_indirect') -WindowStyle Hidden
    Write-Output '  等待启动...'
    $deadline = (Get-Date).AddSeconds(300)
    while ((Get-Date) -lt $deadline) {
      if (Get-Device) {
        $b = & $adb shell getprop sys.boot_completed 2>&1
        if ($b -match '1') { Write-Output '  ✓ 启动完成'; break }
      }
      Start-Sleep -Seconds 3
    }
  }

  'install' {
    & $adb install -r $apk 2>&1 | Select-Object -Last 1 | ForEach-Object { "  $_" }
    & $adb logcat -c 2>&1 | Out-Null
    & $adb shell am force-stop $pkg 2>&1 | Out-Null
    & $adb shell am start -n "$pkg/.MainActivity" 2>&1 | Out-Null
    Start-Sleep -Seconds 6
  }

  'tap' {
    & $adb shell input tap ([int]$Arg1) ([int]$Arg2) 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
  }

  'taps' {
    $xml = Invoke-Dump
    if (-not $xml) { Write-Output '  ! dump 失败'; break }
    $hit = Get-Nodes $xml | Where-Object { $_.Label -match [regex]::Escape($Arg1) } | Select-Object -First 1
    if (-not $hit) { Write-Output "  ! 找不到「$Arg1」"; break }
    Write-Output "  点「$($hit.Label)」@ [$($hit.X),$($hit.Y)]"
    & $adb shell input tap $hit.X $hit.Y 2>&1 | Out-Null
    Start-Sleep -Milliseconds 1200
  }

  'ui' {
    $xml = Invoke-Dump
    if (-not $xml) { Write-Output '  ! dump 失败'; break }
    Get-Nodes $xml | ForEach-Object { "  [$($_.X),$($_.Y)]  $($_.Label)" }
  }

  'shot' {
    $p = Join-Path $devDir 'shot.png'
    & $adb shell screencap -p /sdcard/s.png 2>&1 | Out-Null
    & $adb pull /sdcard/s.png $p 2>&1 | Out-Null
    Write-Output "  $p"
  }

  'logs' {
    Write-Output '=== flutter ==='
    & $adb logcat -d -s flutter 2>&1 | Select-Object -Last 30
    Write-Output '=== 崩溃 ==='
    & $adb logcat -d 2>&1 | Select-String 'FATAL EXCEPTION|AndroidRuntime' | Select-Object -Last 20 | ForEach-Object { "  $_" }
    $p = & $adb shell pidof $pkg 2>&1
    Write-Output "=== pid: $(if($p){$p}else{'!! 进程没了'}) ==="
  }

  'gps' {
    # 灌一个坐标，否则 getCurrentPosition 在模拟器上会超时
    & $adb emu geo fix $Arg1 $Arg2 2>&1 | ForEach-Object { "  $_" }
  }

  default {
    Write-Output @'
用法: .\scripts\emu.ps1 <命令> [参数]

  boot                 启动模拟器并等它开机
  install              装当前 APK 并冷启动（顺带清日志）
  taps <标签>           按语义标签点击 —— 比猜坐标可靠
  tap <x> <y>          按坐标点
  ui                   列出当前界面的所有标签和坐标
  shot                 截图到 dev\shot.png
  logs                 flutter 日志 + 崩溃栈 + 进程状态
  gps <经度> <纬度>      注入模拟坐标（否则定位会超时）

注意：自绘的卡片没有语义标签（比如主页的智能体卡片），
      那些只能用 tap + 从截图量坐标。
'@
  }
}
