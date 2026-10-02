# 配置 Gradle 使用国内镜像。
#
# 为什么必须做（scripts/bench_maven.mjs 实测）：
#   maven.google.com       TIMEOUT      ← 解析 Android 依赖全靠它
#   services.gradle.org    TLS 失败     ← Gradle wrapper 下载 Gradle 自身
#
# ── 上一版踩的坑（值得记下来）──
#
# 第一版用 init.gradle 的 `allprojects { repositories { … } }` 注入镜像，构建报：
#
#   Build was configured to prefer settings repositories over project repositories
#   but repository 'maven' was added by settings file 'settings.gradle.kts'
#
# 两个问题：
#   1. 新版 Gradle 默认 PREFER_SETTINGS，**拒绝**项目级仓库
#   2. 就算能加，`settingsEvaluated` 里追加是**排在后面**的 ——
#      Gradle 按声明顺序尝试，于是仍然先撞 google()（超时），等于没配
#
# 正确做法：直接改 **settings 层的 repositories 声明顺序**，镜像放最前。
# 所以这个脚本改的是 Flutter 的工程模板（顺带让以后新建的项目也自动带镜像），
# 而不是在 init.gradle 里做外围注入。
#
# 用法:
#   & .\scripts\setup_gradle.ps1                  # 只配 init.gradle + 环境变量
#   & .\scripts\setup_gradle.ps1 -PatchTemplates  # 顺带改 Flutter 模板与已有工程
#
# 需要提权（写 C:\dev\）。

[CmdletBinding()]
param(
  [switch]$PatchTemplates,
  [string]$GradleHome = 'C:\dev\gradle-home'
)

$ErrorActionPreference = 'Stop'

$ALIYUN = @(
  'https://maven.aliyun.com/repository/google',
  'https://maven.aliyun.com/repository/central',
  'https://maven.aliyun.com/repository/gradle-plugin',
  'https://maven.aliyun.com/repository/public'
)
$TENCENT_GRADLE = 'https://mirrors.cloud.tencent.com/gradle'

# ─────────────────────────── 1. Gradle 家目录 + init.gradle ───────────────────────────
Write-Host '=== 1. Gradle 家目录与 init.gradle ===' -ForegroundColor Cyan
New-Item -ItemType Directory -Force -Path $GradleHome | Out-Null

$mirrorLines = ($ALIYUN | ForEach-Object { "    '$_'," }) -join "`r`n"
$initGradle = @"
// Tsukiro Chat —— Gradle 国内镜像（外围兜底）
//
// 由 scripts/setup_gradle.ps1 生成。
//
// 注意：**不要在这里用 allprojects { repositories { … } }**。
// 新版 Gradle 默认 PREFER_SETTINGS，项目级仓库会被拒绝并报错。
// Flutter 工程的镜像是在 settings.gradle.kts 的 repositories 块里配的
// （见 scripts/setup_gradle.ps1 -PatchTemplates）。
//
// 这里只覆盖 settings 层，作为非 Flutter 工程的兜底。

def mirrors = [
$mirrorLines
]

settingsEvaluated { settings ->
    // 插件解析（AGP / Kotlin 插件等）
    settings.pluginManagement.repositories {
        mirrors.each { m -> maven { url = m } }
    }
    // 项目依赖（只有工程显式启用了 dependencyResolutionManagement 才存在）
    try {
        settings.dependencyResolutionManagement.repositories {
            mirrors.each { m -> maven { url = m } }
        }
    } catch (Throwable ignored) {
        // 工程没用这个模式，跳过 —— 不是错误
    }
}
"@
$initPath = Join-Path $GradleHome 'init.gradle'
[System.IO.File]::WriteAllText($initPath, $initGradle, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  $initPath"

# ─────────────────────────── 2. 环境变量 ───────────────────────────
Write-Host "`n=== 2. 环境变量 ===" -ForegroundColor Cyan
function Set-UserEnv($name, $value) {
  $current = [Environment]::GetEnvironmentVariable($name, 'User')
  if ($current -eq $value) { Write-Host "  $name 已是 $value"; return }
  [Environment]::SetEnvironmentVariable($name, $value, 'User')
  Write-Host "  $name = $value" -ForegroundColor Green
}
Set-UserEnv 'GRADLE_USER_HOME' $GradleHome
$env:GRADLE_USER_HOME = $GradleHome

# ─────────────────────────── 3. 模板与已有工程 ───────────────────────────
if (-not $PatchTemplates) {
  Write-Host "`n=== 3. 模板补丁 ===" -ForegroundColor Cyan
  Write-Host '  跳过（加 -PatchTemplates 启用）'
  Write-Host '  不启用的话 Flutter 工程仍会卡在 maven.google.com' -ForegroundColor Yellow
  Write-Host "`n完成（未打模板补丁）。" -ForegroundColor White
  return
}

Write-Host "`n=== 3. 给 settings.gradle(.kts) 的 repositories 块插入镜像 ===" -ForegroundColor Cyan

<#
把镜像插到 `repositories {` 之后、`google()` 之前。

顺序是关键：Gradle 按声明顺序**依次尝试**仓库，把镜像放后面等于没配 ——
它会先撞上 maven.google.com 然后超时。
#>
function Patch-SettingsFile {
  param([string]$Path)

  $text = [System.IO.File]::ReadAllText($Path)
  if ($text -match 'maven\.aliyun\.com') {
    Write-Host "  已含镜像，跳过: $(Split-Path $Path -Leaf)" -ForegroundColor DarkGray
    return $false
  }

  $pattern = [regex]'(?m)^([ \t]*)repositories\s*\{\s*\r?\n([ \t]*)google\(\)'
  if (-not $pattern.IsMatch($text)) {
    Write-Host "  未找到 `repositories { google() }` 模式: $(Split-Path $Path -Leaf)" -ForegroundColor DarkGray
    return $false
  }

  $isKts = $Path -like '*.kts*'
  $lines = @()
  foreach ($m in $ALIYUN) {
    $lines += if ($isKts) { "maven(`"$m`")" } else { "maven { url '$m' }" }
  }

  $new = $pattern.Replace($text, {
      param($match)
      $indent = $match.Groups[1].Value
      $inner = $match.Groups[2].Value
      $sb = New-Object System.Text.StringBuilder
      [void]$sb.Append("$indent" + "repositories {" + "`r`n")
      foreach ($l in $lines) { [void]$sb.Append($inner + $l + "`r`n") }
      [void]$sb.Append($inner + "google()")
      return $sb.ToString()
    }, 1)

  [System.IO.File]::WriteAllText($Path, $new, (New-Object System.Text.UTF8Encoding($false)))
  return $true
}

$tmplRoot = 'C:\dev\flutter\packages\flutter_tools\templates'
$tmpls = @(Get-ChildItem $tmplRoot -Recurse -Filter 'settings.gradle*' -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notlike '*.copy.tmpl' })
$n = 0
foreach ($t in $tmpls) {
  if (Patch-SettingsFile -Path $t.FullName) {
    Write-Host "  已改模板: $($t.FullName.Replace($tmplRoot + '\', ''))" -ForegroundColor Green
    $n++
  }
}
Write-Host "  共改 $n 个模板"

$repoRoot = Split-Path -Parent $PSScriptRoot
$projects = @(Get-ChildItem (Join-Path $repoRoot 'packages') -Directory -ErrorAction SilentlyContinue |
              Where-Object { Test-Path (Join-Path $_.FullName 'android\settings.gradle.kts') })
$n = 0
foreach ($p in $projects) {
  if (Patch-SettingsFile -Path (Join-Path $p.FullName 'android\settings.gradle.kts')) {
    Write-Host "  已改工程: $($p.Name)" -ForegroundColor Green
    $n++
  }
}
Write-Host "  共改 $n 个已有工程"

Write-Host "`n完成。重跑构建：flutter build apk --debug" -ForegroundColor White
