# Tsukiro Chat 环境自检
#
# 用法:  & .\scripts\check_env.ps1
#        （本机只装了 Windows PowerShell，不要用 pwsh -File）
#
# 只读脚本，不修改任何东西。受限环境下部分系统查询会失败（已容错）。

$ErrorActionPreference = 'Continue'

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Miss($m) { Write-Host "  [--]   $m" -ForegroundColor DarkGray }
function Warn($m) { Write-Host "  [!!]   $m" -ForegroundColor Yellow }

$repoRoot = Split-Path -Parent $PSScriptRoot

$FLUTTER        = 'C:\dev\flutter\bin\flutter.bat'
$DART_STANDALONE = 'C:\dev\dart-sdk\bin\dart.exe'
$JAVA           = 'C:\dev\jdk\bin\java.exe'
$SDKMAN         = 'C:\dev\android-sdk\cmdline-tools\latest\bin\sdkmanager.bat'
$ADB            = 'C:\dev\android-sdk\platform-tools\adb.exe'

<#
调用外部命令。

**必须这么写**：`$ErrorActionPreference = 'Stop'` 会把原生命令写到 stderr 的
**正常输出**升级成终止错误，而 flutter / java / git / sdkmanager 都爱往 stderr
写进度。结果是"命令成功了脚本却报错退出"。判断成败只看 $LASTEXITCODE。
这个坑在本项目踩了四次，所以固化成函数。
#>
function Invoke-Native {
  param([string]$Exe, [string[]]$Arguments = @(), [int]$Tail = 3)
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $out = & $Exe @Arguments 2>&1
    $code = $LASTEXITCODE
    return @{ code = $code; lines = @($out | Select-Object -Last $Tail) }
  } finally {
    $ErrorActionPreference = $saved
  }
}

Write-Host 'Tsukiro Chat - 开发环境自检' -ForegroundColor White
Write-Host "仓库: $repoRoot"

# ── 基础工具 ──
Section '基础工具链'
foreach ($t in @(
  @{ n = 'git';    e = 'git';    a = @('--version') },
  @{ n = 'node';   e = 'node';   a = @('--version') },
  @{ n = 'python'; e = 'python'; a = @('--version') }
)) {
  if (Get-Command $t.e -ErrorAction SilentlyContinue) {
    $r = Invoke-Native $t.e $t.a 1
    Ok ("{0,-7}: {1}" -f $t.n, ($r.lines -join ' '))
  } else { Miss "$($t.n) : 未安装" }
}

# ── C:\dev 工具链 ──
Section 'C:\dev 工具链'

if (Test-Path $FLUTTER) {
  $r = Invoke-Native $FLUTTER @('--version') 2
  Ok "Flutter : $($r.lines -join ' | ')"
} else { Miss 'Flutter : 未安装（期望 C:\dev\flutter）' }

if (Test-Path $DART_STANDALONE) {
  $r = Invoke-Native $DART_STANDALONE @('--version') 1
  Ok "Dart(独立): $($r.lines -join ' ')"
} else { Miss 'Dart 独立 SDK : 未安装（C:\dev\dart-sdk，仅单测内核时用）' }

if (Test-Path $JAVA) {
  $r = Invoke-Native $JAVA @('-version') 1
  Ok "JDK     : $($r.lines -join ' ')"
} else { Miss 'JDK 17  : 未安装（期望 C:\dev\jdk）' }

if (Test-Path $SDKMAN) {
  Ok 'Android SDK: C:\dev\android-sdk'
  foreach ($p in @('platforms\android-36', 'build-tools\36.0.0', 'platform-tools', 'ndk\28.2.13676358')) {
    $full = Join-Path 'C:\dev\android-sdk' $p
    if (Test-Path $full) { Ok "  $p" } else { Warn "  缺 $p" }
  }
  if (Test-Path $ADB) {
    $r = Invoke-Native $ADB @('devices') 5
    $devices = $r.lines | Where-Object { $_ -match '\tdevice' }
    if ($devices) { Ok "  已连接设备:`n$(($devices | ForEach-Object { "           $_" }) -join "`n")" }
    else { Warn '  没有连接设备（建议真机 —— WebView 行为、权限模型只有真机才真实）' }
  }
} else { Miss 'Android SDK: 未安装（期望 C:\dev\android-sdk）' }

# ── 环境变量 ──
Section '环境变量'
foreach ($v in @('JAVA_HOME', 'ANDROID_HOME', 'ANDROID_SDK_ROOT',
                 'GRADLE_USER_HOME', 'FLUTTER_STORAGE_BASE_URL', 'PUB_HOSTED_URL')) {
  $val = [Environment]::GetEnvironmentVariable($v, 'User')
  if ($val) { Ok "$v = $val" } else { Miss "$v 未设置" }
}

# ── 仓库结构 ──
Section '仓库结构'
foreach ($e in @('docs', 'packages\plugin_core', 'packages\model_gateway',
                 'packages\host_app', 'plugins', 'scripts', 'dev')) {
  if (Test-Path (Join-Path $repoRoot $e)) { Ok $e } else { Warn "缺少: $e" }
}

$docs = @(Get-ChildItem (Join-Path $repoRoot 'docs') -Filter '*.md' -ErrorAction SilentlyContinue)
if ($docs.Count) { Ok "docs/ 下 $($docs.Count) 篇文档" }

$plugins = @(Get-ChildItem (Join-Path $repoRoot 'plugins') -Directory -ErrorAction SilentlyContinue)
if ($plugins.Count) { Ok "plugins/ 下 $($plugins.Count) 个插件：$($plugins.Name -join ', ')" }

# ── 各包状态 ──
Section '各包状态'
foreach ($pkg in @('plugin_core', 'model_gateway', 'host_app')) {
  $dir = Join-Path $repoRoot "packages\$pkg"
  if (-not (Test-Path $dir)) { Miss "$pkg : 不存在"; continue }
  $tests = @(Get-ChildItem (Join-Path $dir 'test') -Filter '*_test.dart' -ErrorAction SilentlyContinue)
  $lock = Test-Path (Join-Path $dir 'pubspec.lock')
  Ok ("{0,-14} {1} 个测试文件，依赖{2}" -f $pkg, $tests.Count, $(if ($lock) { '已解析' } else { '未解析' }))
}

$apk = Join-Path $repoRoot 'packages\host_app\build\app\outputs\flutter-apk\app-debug.apk'
if (Test-Path $apk) {
  Ok ("APK      {0:N1} MB  {1}" -f ((Get-Item $apk).Length / 1MB), (Get-Item $apk).LastWriteTime)
} else {
  Miss 'APK : 还没构建过'
}

# ── Gradle 镜像 ──
Section 'Gradle 国内镜像'
$initGradle = 'C:\dev\gradle-home\init.gradle'
if (Test-Path $initGradle) { Ok "init.gradle 存在" } else { Warn 'init.gradle 缺失 → & .\scripts\setup_gradle.ps1 -PatchTemplates' }

$settingsFiles = @(Get-ChildItem (Join-Path $repoRoot 'packages') -Recurse -Filter 'settings.gradle.kts' -ErrorAction SilentlyContinue |
                   Where-Object { $_.FullName -match '\\android\\' })
foreach ($s in $settingsFiles) {
  $has = (Get-Content $s.FullName -Raw) -match 'maven\.aliyun\.com'
  if ($has) { Ok "镜像已配: $($s.FullName.Replace($repoRoot + '\', ''))" }
  else { Warn "未配镜像: $($s.FullName.Replace($repoRoot + '\', ''))" }
}

# ── 沙箱与网络 ──
Section '环境注意事项'
try { $null = Get-Volume -ErrorAction Stop; Ok 'Get-Volume 可用' }
catch { Warn 'Get-Volume 被拒 —— 读不到磁盘剩余空间，装工具链前请手工确认' }

$curlOk = $false
try {
  $r = & curl.exe -s -o NUL -w '%{http_code}' --max-time 6 https://pub.dev 2>$null
  if ($r -eq '200') { $curlOk = $true }
} catch { }
if ($curlOk) { Ok 'curl TLS 可用' } else { Warn 'curl/pwsh TLS 不可用（SEC_E_NO_CREDENTIALS）→ 用 node/python 下载' }

$probe = Join-Path $PSScriptRoot 'tls_probe.mjs'
if (Test-Path $probe) {
  $out = & node $probe https://pub.dev 2>&1
  if ("$out" -match '^OK 200') { Ok 'Node TLS 可用' } else { Warn 'Node TLS 不可用，检查网络' }

  Section '关键域名（决定 Android 构建能否成功）'
  foreach ($p in @(
    @{ n = 'maven.google.com（Android 依赖）';      u = 'https://maven.google.com/' },
    @{ n = 'services.gradle.org（Gradle 分发）';    u = 'https://services.gradle.org/' },
    @{ n = '阿里云 maven 镜像';                      u = 'https://maven.aliyun.com/repository/google/' },
    @{ n = '腾讯 Gradle 镜像';                       u = 'https://mirrors.cloud.tencent.com/gradle/' },
    @{ n = 'storage.flutter-io.cn';                  u = 'https://storage.flutter-io.cn/' }
  )) {
    $r = & node $probe $p.u 2>&1
    if ("$r" -match '^OK') { Ok "$($p.n)  $r" } else { Warn "$($p.n)  $r" }
  }
  Write-Host '  说明：前两个不通**不代表不能构建** —— 已通过 setup_gradle.ps1 配好国内镜像。' -ForegroundColor DarkGray
}

# ── 下一步 ──
Section '下一步'
if (-not (Test-Path $FLUTTER)) {
  Write-Host '  node scripts\fetch_toolchain.mjs                    # 下载（约 2.2 GB）' -ForegroundColor White
  Write-Host '  & .\scripts\install_toolchain.ps1 -WithAndroidSdk   # 解压安装（需提权）' -ForegroundColor White
  Write-Host '  & .\scripts\setup_gradle.ps1 -PatchTemplates        # 配 Gradle 镜像（需提权）' -ForegroundColor White
} elseif (-not (Test-Path $apk)) {
  Write-Host '  工具链就绪，还没构建过 APK：' -ForegroundColor White
  Write-Host '    cd packages\host_app' -ForegroundColor White
  Write-Host '    & C:\dev\flutter\bin\flutter.bat build apk --debug' -ForegroundColor White
} else {
  Write-Host '  全部就绪。常用命令：' -ForegroundColor White
  Write-Host '    # 纯 Dart 测试（内核 / 模型层）' -ForegroundColor DarkGray
  Write-Host '    cd packages\plugin_core;  & ..\..\scripts\dart.ps1 test' -ForegroundColor White
  Write-Host '    cd packages\model_gateway; & ..\..\scripts\run_live_test.ps1' -ForegroundColor White
  Write-Host '    # Android 构建 / 安装到真机' -ForegroundColor DarkGray
  Write-Host '    cd packages\host_app' -ForegroundColor White
  Write-Host '    & C:\dev\flutter\bin\flutter.bat build apk --debug' -ForegroundColor White
  Write-Host '    & C:\dev\flutter\bin\flutter.bat install --debug' -ForegroundColor White
}

Write-Host ''
