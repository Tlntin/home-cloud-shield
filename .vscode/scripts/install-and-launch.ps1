param(
  [string]$WorkspaceRoot = "",
  [string]$BundleName = "",
  [string]$MainElement = "",
  [string]$ModuleName = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-Json5StringValue {
  param(
    [Parameter(Mandatory = $true)][string]$Content,
    [Parameter(Mandatory = $true)][string]$Key
  )
  $pattern = '"' + [Regex]::Escape($Key) + '"\s*:\s*"([^"]+)"'
  $match = [Regex]::Match($Content, $pattern)
  if ($match.Success) {
    return $match.Groups[1].Value
  }
  return ""
}

function Invoke-Hdc {
  param(
    [Parameter(Mandatory = $true)][string[]]$Args,
    [string]$Step = ""
  )
  if ($Step) {
    Write-Host "[$Step]" -ForegroundColor Cyan
  }
  Write-Host ("$ hdc " + ($Args -join ' '))
  & hdc @Args
  if ($LASTEXITCODE -ne 0) {
    throw "hdc 命令失败，退出码: $LASTEXITCODE"
  }
}

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
  $WorkspaceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

if (-not (Get-Command hdc -ErrorAction SilentlyContinue)) {
  throw "未找到 hdc，请确认已安装并加入 PATH。"
}

$appJsonPath = Join-Path $WorkspaceRoot "AppScope\app.json5"
$moduleJsonPath = Join-Path $WorkspaceRoot "entry\src\main\module.json5"

if (-not (Test-Path $appJsonPath)) {
  throw "未找到 app.json5: $appJsonPath"
}
if (-not (Test-Path $moduleJsonPath)) {
  throw "未找到 module.json5: $moduleJsonPath"
}

$appJsonContent = Get-Content -Path $appJsonPath -Raw -Encoding utf8
$moduleJsonContent = Get-Content -Path $moduleJsonPath -Raw -Encoding utf8

if ([string]::IsNullOrWhiteSpace($BundleName)) {
  $BundleName = Get-Json5StringValue -Content $appJsonContent -Key "bundleName"
}
if ([string]::IsNullOrWhiteSpace($MainElement)) {
  $MainElement = Get-Json5StringValue -Content $moduleJsonContent -Key "mainElement"
}
if ([string]::IsNullOrWhiteSpace($ModuleName)) {
  $ModuleName = Get-Json5StringValue -Content $moduleJsonContent -Key "name"
}

if ([string]::IsNullOrWhiteSpace($BundleName)) {
  throw "无法解析 bundleName（AppScope/app.json5）。"
}
if ([string]::IsNullOrWhiteSpace($MainElement)) {
  throw "无法解析 mainElement（entry/src/main/module.json5）。"
}
if ([string]::IsNullOrWhiteSpace($ModuleName)) {
  throw "无法解析 module name（entry/src/main/module.json5）。"
}

$hapFile = Get-ChildItem -Path $WorkspaceRoot -Recurse -File -Filter "*-signed.hap" |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1

if (-not $hapFile) {
  throw "未找到 signed hap，请先构建。"
}

$hapPath = $hapFile.FullName
$tempDir = "data/local/tmp/" + [Guid]::NewGuid().ToString("N")

Write-Host "Workspace: $WorkspaceRoot" -ForegroundColor DarkGray
Write-Host "BundleName: $BundleName"
Write-Host "MainElement: $MainElement"
Write-Host "ModuleName: $ModuleName"
Write-Host "HAP: $hapPath"

Write-Host "[Force Stop]" -ForegroundColor Cyan
Write-Host "$ hdc shell aa force-stop $BundleName"
& hdc shell aa force-stop $BundleName | Out-Host

Invoke-Hdc -Args @("shell", "mkdir", $tempDir) -Step "Prepare"
Invoke-Hdc -Args @("file", "send", $hapPath, $tempDir) -Step "Upload HAP"
Invoke-Hdc -Args @("shell", "bm", "install", "-p", $tempDir) -Step "Install"
Invoke-Hdc -Args @("shell", "rm", "-rf", $tempDir) -Step "Cleanup"
Invoke-Hdc -Args @("shell", "aa", "start", "-a", $MainElement, "-b", $BundleName, "-m", $ModuleName) -Step "Launch"

Write-Host "`n应用已安装并启动。" -ForegroundColor Green
