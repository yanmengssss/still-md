param(
    [string]$Flutter = 'flutter',
    [string]$Repository = 'yanmengssss/still-md'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location -LiteralPath $projectRoot

function Invoke-Checked {
    param([string]$Program, [string[]]$Arguments)
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE"
    }
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'Git is required.' }
if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'GitHub CLI is required. Install it and run gh auth login.' }
if (-not (Get-Command $Flutter -ErrorAction SilentlyContinue)) { throw "Flutter executable not found: $Flutter" }
if (-not (Test-Path -LiteralPath 'android/key.properties')) { throw 'Missing local Android signing configuration: android/key.properties' }

$versionLine = Get-Content -LiteralPath 'pubspec.yaml' | Where-Object { $_ -match '^version:\s*\d+\.\d+\.\d+\+\d+\s*$' } | Select-Object -First 1
if (-not $versionLine) { throw 'pubspec.yaml must contain a version such as 1.0.1+2.' }
$versionLine -match '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$' | Out-Null
$version = $Matches[1]
$buildNumber = $Matches[2]
$tag = "v$version"

$changes = @(git status --porcelain)
if ($LASTEXITCODE -ne 0) { throw 'Could not check Git status.' }
if ($changes.Count -gt 0) { throw 'Commit or discard all non-ignored changes before publishing.' }

$branch = (git branch --show-current).Trim()
if ($LASTEXITCODE -ne 0 -or -not $branch) { throw 'Check out a branch before publishing.' }
$localCommit = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve local commit.' }
$remoteLine = git ls-remote origin "refs/heads/$branch"
if ($LASTEXITCODE -ne 0 -or -not $remoteLine) { throw "Branch $branch must exist on origin." }
$remoteCommit = ($remoteLine -split '\s+')[0]
if ($localCommit -ne $remoteCommit) { throw "Push branch $branch before publishing; local and remote commits differ." }

$existingTag = git ls-remote --tags origin "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) { throw 'Could not check remote tags.' }
if ($existingTag) { throw "Remote tag $tag already exists. Update the version first." }

Invoke-Checked 'gh' @('auth', 'status')

Write-Host "Building signed release APK for $tag (build $buildNumber)..."
Invoke-Checked $Flutter @('build', 'apk', '--release')

$sourceApk = Join-Path $projectRoot 'build/app/outputs/flutter-apk/app-release.apk'
if (-not (Test-Path -LiteralPath $sourceApk)) { throw "APK was not produced: $sourceApk" }
$releaseDir = Join-Path $projectRoot 'build/release'
New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
$apkName = "StillMD-$tag.apk"
$apkPath = Join-Path $releaseDir $apkName
Copy-Item -LiteralPath $sourceApk -Destination $apkPath -Force
$hash = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = Join-Path $releaseDir "$apkName.sha256"
Set-Content -LiteralPath $checksumPath -Value "$hash  $apkName" -Encoding ascii

$notes = "简阅 MD $version Android 安装包。下载 Assets 中的 $apkName 安装；SHA-256 校验值见同名 .sha256 文件。"
Invoke-Checked 'gh' @('release', 'create', $tag, $apkPath, $checksumPath, '--repo', $Repository, '--target', $branch, '--title', "StillMD $tag", '--notes', $notes)
