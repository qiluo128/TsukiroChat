# 推送到 GitHub。
#
# 设计要点：token 只从环境变量读，**绝不写进任何文件、也不留在 .git/config 里**。
# 脚本执行时会临时把 remote URL 换成带 token 的形式，无论成功失败都在 finally
# 里恢复成干净 URL。
#
# 用法（推荐，token 不进 PowerShell 历史）：
#   $env:GH_TOKEN = '<你的 token>'
#   & .\scripts\push.ps1
#
# 或者只跑一次（注意：会进命令历史）：
#   & .\scripts\push.ps1 -Token '<你的 token>'
#
# 如果还没配过 remote：
#   & .\scripts\push.ps1 -Remote https://github.com/<user>/<repo>.git

[CmdletBinding()]
param(
  [string]$Token = $env:GH_TOKEN,
  [string]$Branch = 'main',
  [string]$Remote,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Fail($msg) {
  Write-Host ''
  Write-Host "✗ $msg" -ForegroundColor Red
  exit 1
}

# ── 前置检查 ──
if (-not $Token) {
  Fail @'
缺少 token。二选一：
  $env:GH_TOKEN = '<token>'; & .\scripts\push.ps1
  & .\scripts\push.ps1 -Token '<token>'

细粒度 PAT 需要同时满足：
  · Repository access 里勾上本仓库
  · Repository permissions → Contents = Read and write
'@
}

if (-not (Test-Path '.git')) { Fail '当前目录不是 git 仓库' }

if ($Remote) {
  git remote remove origin 2>$null
  git remote add origin $Remote
}

$cleanUrl = (git remote get-url origin 2>$null)
if (-not $cleanUrl) { Fail '没有配置 remote origin，用 -Remote 指定' }

# 去掉 URL 里可能已有的凭据，得到干净地址
$cleanUrl = $cleanUrl -replace 'https://[^@/]+@', 'https://'

if ((git status --porcelain)) {
  Write-Host '! 有未提交的改动，将先提交它们' -ForegroundColor Yellow
  git add -A
  git -c user.name="$(git config user.name)" -c user.email="$(git config user.email)" `
      commit --quiet -m "补充：脚本与仓库配置"
}

$authUrl = $cleanUrl -replace '^https://', "https://x-access-token:$Token@"

try {
  git remote set-url origin $authUrl
  $env:GIT_TERMINAL_PROMPT = '0'
  $pushArgs = @('push', '-u', 'origin', "${Branch}:${Branch}")
  if ($Force) { $pushArgs += '--force-with-lease' }

  Write-Host "推送到 $cleanUrl ($Branch) …" -ForegroundColor Cyan

  # 关键：git 把正常进度（"To https://…"、"* [new branch]"）写到 **stderr**。
  # 脚本顶部的 $ErrorActionPreference = 'Stop' 会把 NativeCommandError 升级成
  # 终止错误，导致推送明明成功却提前跳进 finally 并报 exit 1。
  # 因此这里临时降级为 Continue，只依据 $LASTEXITCODE 判断成败。
  $savedEap = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    & git @pushArgs 2>&1 | ForEach-Object { Write-Output "  $_" }
    $code = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = $savedEap
  }

  if ($code -ne 0) {
    Write-Host ''
    Write-Host '✗ 推送失败。按错误特征对照：' -ForegroundColor Red
    Write-Host ''
    Write-Host '  【GH013 / Push Protection / "Push cannot contain secrets"】'
    Write-Host '    提交里含被 GitHub 识别为凭据的内容，被服务端拦下（不是本地问题）。'
    Write-Host '    修法：把凭据从文件里去掉 —— 不要用 GitHub 给的 allow 链接放行，'
    Write-Host '          放行等于把密钥永久留在公开历史里。改完 amend 再推。'
    Write-Host ''
    Write-Host '  【403 Permission denied】'
    Write-Host '    细粒度 PAT 的 Contents 权限是 Read-only。'
    Write-Host '    修法: https://github.com/settings/personal-access-tokens'
    Write-Host '          编辑该 token → Repository permissions → Contents = Read and write'
    Write-Host '          （只需改权限，token 值不变，不用重新生成）'
    Write-Host ''
    Write-Host '  【401 Bad credentials】token 无效或已过期。'
    exit 1
  }

  Write-Host ''
  Write-Host '✓ 推送成功' -ForegroundColor Green
  git --no-pager log --oneline -1
}
finally {
  # 关键：无论成败都把 token 从 .git/config 里摘掉。
  # 用 -c 覆盖而不是直接调用，避免 finally 里的失败掩盖真实错误。
  & git remote set-url origin $cleanUrl 2>$null
  Write-Host "(已恢复 remote 为干净地址: $cleanUrl)"
}
