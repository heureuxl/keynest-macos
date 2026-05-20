#Requires -Version 5.0
# Windows 上打包 macOS 仓库浏览器扩展（与 build-browser-extensions.sh 产物一致，不含 .crx）
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force -Path $dist | Out-Null

function Zip-ExtensionFolder {
    param([string]$SrcDir, [string]$ZipPath, [string]$InnerName)
    if (-not (Test-Path $SrcDir)) { throw "Extension folder not found: $SrcDir" }
    $stage = Join-Path ([System.IO.Path]::GetTempPath()) ("keynest-ext-" + [guid]::NewGuid().ToString("n"))
    $inner = Join-Path $stage $InnerName
    New-Item -ItemType Directory -Force -Path $inner | Out-Null
    Copy-Item -Path (Join-Path $SrcDir "*") -Destination $inner -Recurse -Force
    if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }
    Compress-Archive -Path $inner -DestinationPath $ZipPath -CompressionLevel Optimal
    Remove-Item $stage -Recurse -Force
}

$browser = Join-Path $root "browser"
@(
    @{ Dir = "chrome-extension"; Zip = "KeyNest-Chrome.zip" },
    @{ Dir = "edge-extension"; Zip = "KeyNest-Edge.zip" },
    @{ Dir = "firefox-extension"; Zip = "KeyNest-Firefox.zip" }
) | ForEach-Object {
    Write-Host "==> $($_.Zip)"
    Zip-ExtensionFolder (Join-Path $browser $_.Dir) (Join-Path $dist $_.Zip) "KeyNest"
}

Get-ChildItem -Path $dist -Filter "*.txt" -ErrorAction SilentlyContinue | Remove-Item -Force
$notesDir = Join-Path $PSScriptRoot "extension-install-notes"
$manifestPath = Join-Path $notesDir "notes-manifest.json"
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$utf8Bom = New-Object System.Text.UTF8Encoding $true
$manifest = [System.IO.File]::ReadAllText($manifestPath, $utf8NoBom) | ConvertFrom-Json
foreach ($entry in $manifest.files) {
    $src = Join-Path $notesDir $entry.src
    $text = [System.IO.File]::ReadAllText($src, $utf8NoBom)
    [System.IO.File]::WriteAllText((Join-Path $dist $entry.dest), $text, $utf8Bom)
}

Write-Host "Extension zips and install notes written to: $dist"
