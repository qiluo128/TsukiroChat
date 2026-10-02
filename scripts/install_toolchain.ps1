# 把下载好的工具链解压安装到 C:\dev\。
#
# 前置：node scripts\fetch_toolchain.mjs
#
# 需要提权（写工作区外的 C:\dev\）。
#
# 用法:
#   & .\scripts\install_toolchain.ps1                 # 解压 + 配置环境变量
#   & .\scripts\install_toolchain.ps1 -WithAndroidSdk # 顺带装 Android SDK 组件
#   & .\scripts\install_toolchain.ps1 -SkipFlutter    # 只装某几个
#
# 设计说明：**分步执行、每步可单独重跑**。装 SDK 这种事动辄十几分钟，
# 一个脚本从头跑到尾，中间失败就得全重来，很折磨。

[CmdletBinding()]
param(
  [switch]$SkipFlutter,
  [switch]$SkipJdk,
  [switch]$SkipAndroidTools,
  [switch]$WithAndroidSdk,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$tmp = Join-Path $repoRoot '.tmp'

# 实测最快的源（scripts/bench_toolchain.mjs）
# 不设这个，flutter 工具首次运行会去 storage.googleapis.com 拉自己的 Dart SDK，
# 实测 0.14 MB/s —— 会卡到你以为它死了
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'

function Step($n) { Write-Host "`n=== $n ===" -ForegroundColor Cyan }

<#
调用外部命令。

**为什么必须有这个包装**：PowerShell 的 $ErrorActionPreference = 'Stop' 会把
原生命令写到 **stderr** 的输出包装成 NativeCommandError，升级为终止错误。
而大量工具（flutter、git、java、sdkmanager…）把**正常进度**写在 stderr：

    flutter.bat : Building flutter tool...

结果就是"命令明明成功了，脚本却报错退出"。

这个坑在本项目已经踩了三次（push.ps1 首推、dart test、这次的 flutter），
所以做成公用函数，而不是每次在调用点临时改 ErrorActionPreference。
判断成败只看 $LASTEXITCODE，不看有没有 stderr 输出。
#>
function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$Exe,
    [string[]]$Arguments = @(),
    [string]$Label = '',
    [int]$Tail = 6
  )
  if ($Label) { Write-Host "  $Label" }
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $output = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    $output | Select-Object -Last $Tail | ForEach-Object { Write-Host "    $_" }
    return $code
  } finally {
    $ErrorActionPreference = $saved
  }
}

function Expand-Zip($zip, $destination, $label) {
  if (-not (Test-Path $zip)) { throw "找不到 $zip（先跑 node scripts\fetch_toolchain.mjs）" }
  Write-Host "  解压 $label …"
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $destination)
  $sw.Stop()
  Write-Host ("  完成，{0:N1}s" -f $sw.Elapsed.TotalSeconds)
}

New-Item -ItemType Directory -Force -Path 'C:\dev' | Out-Null

# ─────────────────────────── Flutter ───────────────────────────
if (-not $SkipFlutter) {
  Step 'Flutter SDK'
  $junk = Get-ChildItem $tmp -Filter 'flutter_*-stable.zip' -ErrorAction SilentlyContinue |
          Where-Object { $_.Name -notlike '*.part' } | Select-Object -First 1
  if (-not $junk) { throw '找不到 flutter zip' }

  if ((Test-Path 'C:\dev\flutter') -and $Force) { Remove-Item 'C:\dev\flutter' -Recurse -Force }
  if (Test-Path 'C:\dev\flutter') {
    Write-Host '  C:\dev\flutter 已存在，跳过解压'
  } else {
    # flutter zip 里顶层就是 flutter/，直接解到 C:\dev\ 即可
    Expand-Zip $junk.FullName 'C:\dev' 'flutter'
  }

  Write-Host '  首次运行会下载它自带的 Dart SDK（走国内镜像）…'
  Invoke-Native -Exe 'C:\dev\flutter\bin\flutter.bat' -Arguments @('--version') -Tail 6 | Out-Null
}

# ─────────────────────────── JDK ───────────────────────────
if (-not $SkipJdk) {
  Step 'JDK 17'
  $jdkZip = Join-Path $tmp 'OpenJDK17U-jdk_x64_windows_hotspot_17.0.20.1_1.zip'
  if ((Test-Path 'C:\dev\jdk') -and $Force) { Remove-Item 'C:\dev\jdk' -Recurse -Force }

  if (Test-Path 'C:\dev\jdk\bin\java.exe') {
    Write-Host '  C:\dev\jdk 已存在，跳过'
  } else {
    $staging = 'C:\dev\_jdk_staging'
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging | Out-Null
    Expand-Zip $jdkZip $staging 'jdk'
    # zip 里是 jdk-17.0.20.1+1/ 这种带版本号的目录，改名成稳定的 jdk\
    $inner = Get-ChildItem $staging -Directory | Select-Object -First 1
    if (-not $inner) { throw 'jdk zip 结构不符合预期' }
    Move-Item $inner.FullName 'C:\dev\jdk'
    Remove-Item $staging -Recurse -Force
  }

  Invoke-Native -Exe 'C:\dev\jdk\bin\java.exe' -Arguments @('-version') -Tail 2 | Out-Null
}

# ─────────────────────────── Android cmdline-tools ───────────────────────────
if (-not $SkipAndroidTools) {
  Step 'Android cmdline-tools'
  $clZip = Join-Path $tmp 'commandlinetools-win.zip'
  $clRoot = 'C:\dev\android-sdk\cmdline-tools'
  $clLatest = Join-Path $clRoot 'latest'

  if ((Test-Path $clLatest) -and $Force) { Remove-Item $clLatest -Recurse -Force }

  if (Test-Path (Join-Path $clLatest 'bin\sdkmanager.bat')) {
    Write-Host '  cmdline-tools 已存在，跳过'
  } else {
    # sdkmanager 要求路径必须是 <sdk>/cmdline-tools/latest/bin/…
    # 直接把 zip 解到 cmdline-tools/ 是错的（会变成 cmdline-tools/cmdline-tools/bin）
    $staging = 'C:\dev\_clt_staging'
    if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $staging, $clRoot | Out-Null
    Expand-Zip $clZip $staging 'cmdline-tools'
    $inner = Join-Path $staging 'cmdline-tools'
    if (-not (Test-Path $inner)) { throw 'cmdline-tools zip 结构不符合预期' }
    if (Test-Path $clLatest) { Remove-Item $clLatest -Recurse -Force }
    Move-Item $inner $clLatest
    Remove-Item $staging -Recurse -Force
  }
  Write-Host "  sdkmanager: $clLatest\bin\sdkmanager.bat"
}

# ─────────────────────────── 环境变量 ───────────────────────────
Step '环境变量（用户级，不需要管理员）'

function Set-UserEnv($name, $value) {
  $current = [Environment]::GetEnvironmentVariable($name, 'User')
  if ($current -eq $value) { Write-Host "  $name 已是 $value"; return }
  [Environment]::SetEnvironmentVariable($name, $value, 'User')
  Write-Host "  $name = $value" -ForegroundColor Green
}

Set-UserEnv 'JAVA_HOME' 'C:\dev\jdk'
Set-UserEnv 'ANDROID_HOME' 'C:\dev\android-sdk'
Set-UserEnv 'ANDROID_SDK_ROOT' 'C:\dev\android-sdk'
Set-UserEnv 'FLUTTER_STORAGE_BASE_URL' 'https://storage.flutter-io.cn'
Set-UserEnv 'PUB_HOSTED_URL' 'https://pub.flutter-io.cn'

# PATH 里补 flutter / jdk / platform-tools，避免重复追加
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$need = @('C:\dev\flutter\bin', 'C:\dev\jdk\bin', 'C:\dev\android-sdk\platform-tools')
$parts = $userPath -split ';' | Where-Object { $_ -ne '' }
$added = @()
foreach ($p in $need) {
  if ($parts -notcontains $p) { $parts += $p; $added += $p }
}
if ($added.Count) {
  [Environment]::SetEnvironmentVariable('PATH', ($parts -join ';'), 'User')
  Write-Host "  PATH 新增: $($added -join ', ')" -ForegroundColor Green
} else {
  Write-Host '  PATH 已包含全部工具链路径'
}

# 当前会话也生效
$env:JAVA_HOME = 'C:\dev\jdk'
$env:ANDROID_HOME = 'C:\dev\android-sdk'
$env:ANDROID_SDK_ROOT = 'C:\dev\android-sdk'
$env:PATH = "C:\dev\flutter\bin;C:\dev\jdk\bin;$env:PATH"

# ─────────────────────────── Android SDK 组件 ───────────────────────────
if ($WithAndroidSdk) {
  Step 'Android SDK 组件'
  $sdkmanager = 'C:\dev\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat'
  if (-not (Test-Path $sdkmanager)) { throw '找不到 sdkmanager' }

  Write-Host '  接受许可协议…'
  # sdkmanager 会问一堆 y/n；管道喂 yes
  $yes = ("y`n" * 30)
  $yes | & $sdkmanager --sdk_root='C:\dev\android-sdk' --licenses 2>&1 | Select-Object -Last 3

  Write-Host '  安装 platform-tools / platforms;android-34 / build-tools;34.0.0 …'
  Invoke-Native -Exe $sdkmanager -Arguments @('--sdk_root=C:\dev\android-sdk', 'platform-tools', 'platforms;android-34', 'build-tools;34.0.0') -Tail 8 | Out-Null
}

# ─────────────────────────── 收尾 ───────────────────────────
Step '下一步'
Write-Host '  cd C:\Users\24074\Documents\TsukiroChat'
Write-Host '  & .\scripts\check_env.ps1                 # 自检'
Write-Host '  & C:\dev\flutter\bin\flutter.bat doctor   # Flutter 体检'
if (-not $WithAndroidSdk) {
  Write-Host ''
  Write-Host '  还没装 Android SDK 组件。装法：' -ForegroundColor Yellow
  Write-Host '    & .\scripts\install_toolchain.ps1 -SkipFlutter -SkipJdk -SkipAndroidTools -WithAndroidSdk'
}