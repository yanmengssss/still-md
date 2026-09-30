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
if (-not (Get-Command $Flutter -ErrorAction SilentlyContinue)) { throw "Flutter executable not found: $Flutter" }
if (-not (Test-Path -LiteralPath 'android/key.properties')) { throw 'Missing local Android signing configuration: android/key.properties' }
if ($Repository -notmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Repository must be in owner/name form.' }

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

$credentialLines = @('protocol=https', 'host=github.com', '') | git credential fill
if ($LASTEXITCODE -ne 0) { throw 'Could not read the existing GitHub login from Git Credential Manager.' }
$tokenLine = $credentialLines | Where-Object { $_ -like 'password=*' } | Select-Object -First 1
if (-not $tokenLine) { throw 'No GitHub credential found. Sign in through Git and retry.' }
$githubToken = $tokenLine.Substring(9)
$headers = @{
    Authorization = "Bearer $githubToken"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
    'User-Agent' = 'StillMD-Release'
}
$apiBase = "https://api.github.com/repos/$Repository/releases"
$releases = Invoke-RestMethod -Method Get -Headers $headers -Uri $apiBase
$release = @($releases) | Where-Object { $_.tag_name -eq $tag } | Select-Object -First 1
if ($release -and -not $release.draft) { throw "Release $tag is already published. Update the version first." }

$existingTag = git ls-remote --tags origin "refs/tags/$tag"
if ($LASTEXITCODE -ne 0) { throw 'Could not check remote tags.' }
if ($existingTag -and -not $release) { throw "Remote tag $tag already exists. Update the version first." }

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
if (-not $release) {
    $body = @{
        tag_name = $tag
        target_commitish = $branch
        name = "StillMD $tag"
        body = $notes
        draft = $true
        prerelease = $false
    } | ConvertTo-Json
    $release = Invoke-RestMethod -Method Post -Headers $headers -Uri $apiBase -ContentType 'application/json' -Body $body
}

$uploadBase = $release.upload_url.Split('{')[0]
foreach ($filePath in @($apkPath, $checksumPath)) {
    $fileName = Split-Path -Leaf $filePath
    $existingAsset = @($release.assets) | Where-Object { $_.name -eq $fileName } | Select-Object -First 1
    if ($existingAsset) {
        if ($existingAsset.state -ne 'uploaded' -or $existingAsset.size -ne (Get-Item -LiteralPath $filePath).Length) {
            throw "Draft already has a different asset named $fileName. Inspect the draft on GitHub."
        }
        continue
    }
    $contentType = if ($fileName.EndsWith('.apk')) { 'application/vnd.android.package-archive' } else { 'text/plain' }
    $uploadUrl = "$uploadBase`?name=$([uri]::EscapeDataString($fileName))"
    Invoke-RestMethod -Method Post -Headers $headers -Uri $uploadUrl -ContentType $contentType -InFile $filePath | Out-Null
}

$release = Invoke-RestMethod -Method Get -Headers $headers -Uri "$apiBase/$($release.id)"
foreach ($fileName in @($apkName, "$apkName.sha256")) {
    $asset = @($release.assets) | Where-Object { $_.name -eq $fileName -and $_.state -eq 'uploaded' } | Select-Object -First 1
    if (-not $asset) { throw "Release asset missing after upload: $fileName" }
}
$release = Invoke-RestMethod -Method Patch -Headers $headers -Uri "$apiBase/$($release.id)" -ContentType 'application/json' -Body '{"draft":false}'
Write-Host "Published $($release.html_url)"
