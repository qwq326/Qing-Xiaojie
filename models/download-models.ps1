<#
.SYNOPSIS
    从 GitHub Release 下载晴小姐的模型权重，并校验 SHA256。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File models\download-models.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File models\download-models.ps1 -Tag v1.0.0 -Dest D:\models
#>
param(
    [string]$Tag = 'v1.0.0',
    [string]$Dest = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$repo = 'qwq326/Qing-Xiaojie'

$Expected = [ordered]@{
    'Qing2.0-e25.ckpt'        = '71860F8B821C1E66419F98CCBCBA99D9D34CF2300E41ADABF7CE35F9DAE51825'
    'Qing2.0_e3_s876_l64.pth' = '0A99E2534B4C4B93E23F06603920A72B3C095C081CC87184A252A1CD4335ABD3'
}

if (-not (Test-Path -LiteralPath $Dest)) {
    New-Item -ItemType Directory -Path $Dest -Force | Out-Null
}

Write-Host ('Release : ' + $repo + ' @ ' + $Tag) -ForegroundColor Cyan
Write-Host ('Target  : ' + $Dest) -ForegroundColor Cyan

try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/tags/$Tag" `
        -Headers @{ 'User-Agent' = 'qing-downloader'; 'Accept' = 'application/vnd.github+json' }
} catch {
    Write-Host ('无法读取 Release 信息：' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '请手动到仓库的 Releases 页面下载权重。' -ForegroundColor Yellow
    exit 1
}

$failed = $false
foreach ($name in $Expected.Keys) {
    $target = Join-Path $Dest $name
    $want = $Expected[$name]

    if (Test-Path -LiteralPath $target) {
        $have = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($have -eq $want) {
            Write-Host ('已存在且校验通过：' + $name) -ForegroundColor Green
            continue
        }
        Write-Host ('已存在但校验不符，重新下载：' + $name) -ForegroundColor Yellow
        Remove-Item -LiteralPath $target -Force
    }

    $asset = $release.assets | Where-Object { $_.name -eq $name } | Select-Object -First 1
    if (-not $asset) {
        Write-Host ('Release 中找不到资产：' + $name) -ForegroundColor Red
        $failed = $true
        continue
    }

    Write-Host ('下载 ' + $name + ' (' + [math]::Round($asset.size / 1MB, 1) + ' MB) ...') -ForegroundColor Gray
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $target -UseBasicParsing

    $have = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
    if ($have -eq $want) {
        Write-Host ('  校验通过：' + $name) -ForegroundColor Green
    } else {
        Write-Host ('  校验失败：期望 ' + $want + '，实际 ' + $have) -ForegroundColor Red
        $failed = $true
    }
}

Write-Host ''
if ($failed) {
    Write-Host '部分文件下载/校验失败，请重试或手动从 Releases 下载。' -ForegroundColor Red
    exit 1
}

Write-Host '全部完成。把两个文件放到 GPT-SoVITS 的权重目录：' -ForegroundColor Cyan
Write-Host '  <GPT-SoVITS>\GPT_weights_v3\Qing2.0-e25.ckpt' -ForegroundColor Gray
Write-Host '  <GPT-SoVITS>\SoVITS_weights_v3\Qing2.0_e3_s876_l64.pth' -ForegroundColor Gray
Write-Host '然后在 config.ps1 中填写 GptWeights / SovitsWeights。' -ForegroundColor Gray
