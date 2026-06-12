<#
.SYNOPSIS
  校验本地构建产物版本并上传 HAP 到对应 GitHub Release 附件。
.DESCRIPTION
  1. 读取 entry/build/default/outputs/default/pack.info,取版本号。
  2. 确认与指定 tag (vX.Y.Z) 一致。
  3. 通过 gh CLI 将 entry-default-unsigned.hap 上传到该 Release。
.EXAMPLE
  .\.github\scripts\upload-hap.ps1            # 自动使用 pack.info 中的版本对应的 tag
  .\.github\scripts\upload-hap.ps1 -Tag v0.0.7
#>
param(
    [string]$Tag
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$outDir = Join-Path $root 'entry\build\default\outputs\default'
$packInfoPath = Join-Path $outDir 'pack.info'
$hapPath = Join-Path $outDir 'entry-default-unsigned.hap'

if (-not (Test-Path $packInfoPath)) { throw "未找到 $packInfoPath,请先构建 HAP" }
if (-not (Test-Path $hapPath))      { throw "未找到 $hapPath,请先构建 HAP" }

$packInfo = Get-Content $packInfoPath -Raw | ConvertFrom-Json
$buildVersion = $packInfo.summary.app.version.name
Write-Host "pack.info 版本: $buildVersion"

if (-not $Tag) { $Tag = "v$buildVersion" }
$tagVersion = $Tag.TrimStart('v')

if ($tagVersion -ne $buildVersion) {
    throw "版本不一致: tag=$Tag, pack.info=$buildVersion。请重新构建或检查 tag。"
}

# 确认 Release 存在(由 GitHub Actions 在推 tag 后自动创建)
gh release view $Tag --json tagName | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw "Release $Tag 不存在。请先推送 tag 并等待 GitHub Actions 创建 Release。"
}

$assetName = "home_cloud_shield-$Tag-unsigned.hap"
Write-Host "上传 $hapPath -> Release $Tag (附件名: $assetName)"
gh release upload $Tag "$hapPath#$assetName" --clobber
if ($LASTEXITCODE -ne 0) { throw '上传失败' }

Write-Host "完成: https://github.com/Tlntin/home-cloud-shield/releases/tag/$Tag"
