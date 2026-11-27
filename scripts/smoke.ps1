$ErrorActionPreference = 'Stop'
$mode = $env:RELEASE_MODE
if ($mode -cnotin @('draft', 'live')) { throw 'Mode must be draft or live.' }
$tag = $env:RELEASE_TAG
if ($tag -cnotmatch '^v(\d+)\.(\d+)\.(\d+)$') { throw 'Tag must look like v0.1.0.' }
$version = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0"
foreach ($entry in @(@('setup', $env:SETUP_SHA256, 64), @('executable', $env:EXE_SHA256, 64))) {
    if ($entry[1] -notmatch "^[0-9a-fA-F]{$($entry[2])}$") { throw "Invalid $($entry[0]) checksum." }
}
$release = gh release view $tag --repo toshodin/dendrokeeper-releases --json isDraft,tagName,assets | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Could not retrieve the release.' }
if ($release.tagName -cne $tag -or ($mode -ceq 'draft' -and -not $release.isDraft) -or ($mode -ceq 'live' -and $release.isDraft)) { throw "The tag must identify a $mode release." }
$assets = @($release.assets)
$product = if ($tag -ceq 'v0.1.0') { 'DendroKeeper' } else { 'CallToMind' }
$setup = "$product-$version-win-x64-setup.exe"
$base = "$product-$version-win-x64.7z"
$parts = @($assets | Where-Object { $_.name -cmatch ('^' + [regex]::Escape($base) + '\.part\d{3}$') } | Sort-Object name)
$wholePackage = @($assets | Where-Object { $_.name -ceq $base })
if ($mode -ceq 'draft' -and ($wholePackage.Count -gt 1 -or ($wholePackage.Count -gt 0 -and $parts.Count -gt 0))) { throw 'Expected one package format.' }
if ($mode -ceq 'draft' -and ($parts.Count -gt 0 -or $wholePackage.Count -gt 0) -and $env:PACKAGE_SHA512 -notmatch '^[0-9a-fA-F]{128}$') { throw 'A package SHA-512 is required when parts are present.' }
for ($i = 0; $mode -ceq 'draft' -and $i -lt $parts.Count; $i++) {
    if ($parts[$i].name -cne ("$base.part{0:D3}" -f ($i + 1))) { throw 'Package parts are not contiguous from part001.' }
}
$dir = Join-Path $env:RUNNER_TEMP 'dendro-release-smoke'
New-Item -ItemType Directory -Path $dir | Out-Null
function Download-Asset([string] $name) {
    if (@($assets | Where-Object { $_.name -ceq $name }).Count -ne 1) { throw "Expected one asset named $name." }
    gh release download $tag --repo toshodin/dendrokeeper-releases --pattern $name --dir $dir
    if ($LASTEXITCODE -ne 0) { throw "Download failed: $name." }
}
if ($mode -ceq 'draft') {
    Download-Asset $setup
} else {
    $downloadUrl = if ($tag -ceq 'v0.1.0') { 'https://dendro-keeper.com/downloads/windows-setup' } else { 'https://calltomind.app/downloads/windows-setup' }
    Invoke-WebRequest -Uri $downloadUrl -OutFile (Join-Path $dir $setup) -TimeoutSec 300
}
Download-Asset 'SHA256SUMS.txt'
$manifest = Get-Content -LiteralPath (Join-Path $dir 'SHA256SUMS.txt')
function Assert-Manifest([string] $name, [string] $expected) {
    $lines = @($manifest | Where-Object { $_ -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($name) + '$') })
    if ($lines.Count -ne 1 -or $lines[0].Substring(0, 64) -ine $expected) { throw "Manifest checksum does not match the independent value for $name." }
}
Assert-Manifest $setup $env:SETUP_SHA256
if ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $dir $setup)).Hash -ine $env:SETUP_SHA256) { throw 'Setup checksum mismatch.' }
$upgrade = $mode -ceq 'draft' -and $tag -cne 'v0.1.0'
$arguments = @('/S')
if ($mode -ceq 'live') {
    Write-Host 'Running the published setup with its configured package download.'
} elseif ($wholePackage.Count -gt 0) {
    Download-Asset $base
    $packagePath = Join-Path $dir $base
    if ((Get-FileHash -Algorithm SHA512 -LiteralPath $packagePath).Hash -ine $env:PACKAGE_SHA512) { throw 'Package checksum mismatch.' }
    $arguments += "--package-file=`"$packagePath`""
} elseif ($parts.Count -gt 0) {
    $packagePath = Join-Path $dir $base
    $output = [System.IO.File]::Create($packagePath)
    try {
        foreach ($part in $parts) {
            Download-Asset $part.name
            $inputStream = [System.IO.File]::OpenRead((Join-Path $dir $part.name))
            try { $inputStream.CopyTo($output) } finally { $inputStream.Dispose() }
            Remove-Item -LiteralPath (Join-Path $dir $part.name)
        }
    } finally { $output.Dispose() }
    if ((Get-FileHash -Algorithm SHA512 -LiteralPath $packagePath).Hash -ine $env:PACKAGE_SHA512) { throw 'Assembled package checksum mismatch.' }
    $arguments += "--package-file=`"$packagePath`""
} else {
    Write-Host 'No package parts found. Setup will use its configured download.'
}
Remove-Item Env:GH_TOKEN
if ($upgrade) {
    . "$PSScriptRoot/upgrade.ps1"
    Install-PreviousRelease
    Test-CorruptUpgrade (Join-Path $dir $setup)
}
$setupPath = Join-Path $dir $setup
$installer = Start-Process -FilePath $setupPath -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
if ($installer.ExitCode -ne 0) { throw "Setup failed with exit code $($installer.ExitCode)." }
$menu = [Environment]::GetFolderPath('Programs')
$shortcut = if ($tag -ceq 'v0.1.0') { 'Dendro Keeper.lnk' } else { 'Call to Mind.lnk' }
$links = @(Get-ChildItem -LiteralPath $menu -Recurse -File -Filter $shortcut)
if ($links.Count -ne 1) { throw "Expected one per-user Start menu shortcut, found $($links.Count)." }
$shell = New-Object -ComObject WScript.Shell
$exe = $shell.CreateShortcut($links[0].FullName).TargetPath
$expectedExe = if ($tag -ceq 'v0.1.0') { 'DendroKeeper.exe' } else { 'CallToMind.exe' }
if ([IO.Path]::GetFileName($exe) -ine $expectedExe) { throw 'Unexpected Start menu target.' }
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Installed executable missing: $exe" }
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash -ine $env:EXE_SHA256) { throw 'Installed executable checksum mismatch.' }
if ($upgrade) {
    $alias = Join-Path (Split-Path $exe) 'DendroKeeper.exe'
    if (-not (Test-Path -LiteralPath $alias -PathType Leaf)) { throw 'Compatibility executable missing.' }
    Test-PreviousData $exe -workspace:($tag -ceq 'v0.1.2')
    return
}
$env:MEETING_CAPTURE_HOME = Join-Path $dir 'home'
$env:MEETING_CAPTURE_FAKE_CONTROL = Join-Path $dir 'control'
$env:MEETING_CAPTURE_FAKES = '1'
$env:MEETING_CAPTURE_FAKE_EVENT_PORT = '0'
New-Item -ItemType Directory -Path $env:MEETING_CAPTURE_HOME, $env:MEETING_CAPTURE_FAKE_CONTROL | Out-Null
'{"items":[]}' | Set-Content -Encoding utf8 (Join-Path $env:MEETING_CAPTURE_FAKE_CONTROL 'calendar.json')
$app = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden
try {
    $addressFile = Join-Path $env:MEETING_CAPTURE_HOME 'window-url.txt'
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath $addressFile)) {
        $app.Refresh()
        if ($app.HasExited) { throw "App exited before boot: $($app.ExitCode)." }
        if ((Get-Date) -gt $deadline) { throw 'App did not announce its window within 90 seconds.' }
        Start-Sleep -Milliseconds 500
    }
    $address = (Get-Content -LiteralPath $addressFile -Raw).Trim()
    $uri = [uri]$address
    if ($uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1') { throw 'App window address is not on loopback.' }
    $page = Invoke-WebRequest -Uri $uri -TimeoutSec 10
    if ($page.StatusCode -ne 200 -or $page.Content -notmatch $(if ($tag -ceq 'v0.1.0') { 'Dendro Keeper' } else { 'Call to Mind' })) { throw 'App window did not return the expected page.' }
    $token = [System.Web.HttpUtility]::ParseQueryString($uri.Query).Get('t')
    if (-not $token) { throw 'App window token missing.' }
    $origin = "http://127.0.0.1:$($uri.Port)"
    $headers = @{ 'X-Token' = $token }
    $licence = Invoke-RestMethod -Uri "$origin/api/licence" -Headers $headers -TimeoutSec 10
    $status = Invoke-RestMethod -Uri "$origin/api/status" -Headers $headers -TimeoutSec 10
    if ($licence.plan -cne 'solo') { throw 'Expected the solo licence plan.' }
    if ($status.recorder.state -cne 'idle') { throw 'Expected the recorder to be idle.' }
    Write-Host 'Installed executable passed its checksum and its test-mode window responded.'
} finally {
    $app.Refresh()
    if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force }
}
