$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') { throw 'Upgrade checks require a GitHub-hosted runner.' }
$oldSetupHash = '37c8153126a2eaeb079f31e16a63297d66e84297a2f33c557212c462c5e34a93'
$oldPackageHash = '60298757acd8c5915dce5d236f2e27e5c9b2ff83bb57b4e343569c8ee277c3dd'
$oldExeHash = '49ce280d61790d40654267b9796a5f9cc2b5765021db61bd920706889606c82a'
$syntheticHome = Join-Path $dir 'synthetic-data'
$pointer = Join-Path $env:USERPROFILE '.dendro-keeper-folder'
$env:MEETING_CAPTURE_FAKE_CONTROL = Join-Path $dir 'control'
$env:MEETING_CAPTURE_FAKES = '1'
$env:MEETING_CAPTURE_FAKE_EVENT_PORT = '0'
Remove-Item Env:MEETING_CAPTURE_HOME -ErrorAction SilentlyContinue

function Invoke-Setup([string] $file, [string] $package) {
    $process = Start-Process -FilePath $file -ArgumentList @('/S', "--package-file=`"$package`"") -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Test-PreviousData([string] $executable) {
    $addressFile = Join-Path $syntheticHome 'window-url.txt'
    Remove-Item -LiteralPath $addressFile -ErrorAction SilentlyContinue
    $app = Start-Process -FilePath $executable -PassThru -WindowStyle Hidden
    try {
        $deadline = (Get-Date).AddSeconds(90)
        while (-not (Test-Path -LiteralPath $addressFile)) {
            $app.Refresh()
            if ($app.HasExited) { throw "App exited before boot: $($app.ExitCode)." }
            if ((Get-Date) -gt $deadline) { throw 'App did not start within 90 seconds.' }
            Start-Sleep -Milliseconds 500
        }
        $uri = [uri](Get-Content -LiteralPath $addressFile -Raw).Trim()
        if ($uri.Scheme -cne 'http' -or $uri.Host -cne '127.0.0.1') { throw 'App address is not on loopback.' }
        $token = [System.Web.HttpUtility]::ParseQueryString($uri.Query).Get('t')
        if (-not $token) { throw 'App token missing.' }
        $origin = "http://127.0.0.1:$($uri.Port)"
        $headers = @{ 'X-Token' = $token }
        $meetings = Invoke-RestMethod -Uri "$origin/api/meetings" -Headers $headers -TimeoutSec 10
        if (@($meetings.meetings | Where-Object { $_.id -ceq '2026-11-20_090000_000' -and $_.title -ceq 'Synthetic upgrade meeting' }).Count -ne 1) { throw 'Synthetic meeting is not visible.' }
        $settings = Invoke-RestMethod -Uri "$origin/api/settings" -Headers $headers -TimeoutSec 10
        if ($settings.retention_days -ne 12 -or $settings.recordings_in_use -ine (Join-Path $syntheticHome 'recordings')) { throw 'Existing settings or data pointer were not used.' }
        $models = Invoke-RestMethod -Uri "$origin/api/models" -Headers $headers -TimeoutSec 10
        if (@($models.endpoints | Where-Object { $_.id -ceq 'local' -and $_.model -ceq 'synthetic-model' }).Count -ne 1) { throw 'Existing model settings were not used.' }
        if ((Get-Content -LiteralPath (Join-Path $env:HF_HOME 'model-sentinel.txt') -Raw).Trim() -cne 'synthetic model cache') { throw 'Model cache sentinel changed.' }
        Write-Host "Synthetic meeting, settings and model cache verified in $([IO.Path]::GetFileName($executable))."
    } finally {
        $app.Refresh()
        if (-not $app.HasExited) { Stop-Process -Id $app.Id -Force; $app.WaitForExit() }
    }
}

function Install-PreviousRelease {
    if (Test-Path -LiteralPath $pointer) { throw 'Runner profile already has a data pointer.' }
    $oldSetup = Join-Path $dir 'previous-setup.exe'
    $oldPackage = Join-Path $dir 'previous.7z'
    gh release download v0.1.0 --repo toshodin/dendrokeeper-releases --pattern 'DendroKeeper-0.1.0.0-win-x64-setup.exe' --dir $dir
    if ($LASTEXITCODE -ne 0) { throw 'Previous setup download failed.' }
    Move-Item -LiteralPath (Join-Path $dir 'DendroKeeper-0.1.0.0-win-x64-setup.exe') -Destination $oldSetup
    if ((Get-FileHash -Algorithm SHA256 $oldSetup).Hash -ine $oldSetupHash) { throw 'Previous setup checksum mismatch.' }
    Invoke-WebRequest -Uri 'https://dendro-keeper.com/downloads/v0.1.0/DendroKeeper-0.1.0.0-win-x64.7z' -OutFile $oldPackage -TimeoutSec 900
    if ((Get-FileHash -Algorithm SHA256 $oldPackage).Hash -ine $oldPackageHash) { throw 'Previous package checksum mismatch.' }
    if ((Invoke-Setup $oldSetup $oldPackage) -ne 0) { throw 'Previous setup failed.' }
    Remove-Item -LiteralPath $oldSetup, $oldPackage
    $link = @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Programs')) -Recurse -File -Filter 'Dendro Keeper.lnk')
    if ($link.Count -ne 1) { throw 'Previous shortcut missing or ambiguous.' }
    $script:oldExe = (New-Object -ComObject WScript.Shell).CreateShortcut($link[0].FullName).TargetPath
    if ((Get-FileHash -Algorithm SHA256 $script:oldExe).Hash -ine $oldExeHash) { throw 'Previous executable checksum mismatch.' }
    New-Item -ItemType Directory -Force -Path $syntheticHome, $env:MEETING_CAPTURE_FAKE_CONTROL, (Join-Path $syntheticHome 'recordings/2026-11-20_090000_000'), (Join-Path $syntheticHome 'outbox/synthetic/2026-11-20-synthetic-upgrade-meeting') | Out-Null
    $env:HF_HOME = Join-Path $dir 'synthetic-models'
    New-Item -ItemType Directory -Path $env:HF_HOME | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:HF_HOME 'model-sentinel.txt'), 'synthetic model cache')
    [IO.File]::WriteAllText($pointer, "$syntheticHome`n")
    [IO.File]::WriteAllText((Join-Path $env:MEETING_CAPTURE_FAKE_CONTROL 'calendar.json'), '{"items":[]}')
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'recordings/2026-11-20_090000_000/meeting.json'), '{"title":"Synthetic upgrade meeting","source":"unsorted"}')
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'recordings/2026-11-20_090000_000/filed.json'), '{"folder":"2026-11-20-synthetic-upgrade-meeting"}')
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'outbox/synthetic/2026-11-20-synthetic-upgrade-meeting/summary.md'), 'Synthetic summary')
    $config = @'
contributor = "synthetic"
user_names = ["Synthetic"]
poll_seconds = 60
retention_days = 12
default_manual_only = true
[[models]]
id = "local"
name = "Synthetic model"
url = "http://127.0.0.1:8000/v1"
model = "synthetic-model"
[model_for]
summary = "local"
actions = "local"
screenshots = "local"
[calendar]
client_file = ""
[delivery]
host = ""
root = ""
[unsorted]
folder = "synthetic"
action_log = "synthetic/actions.md"
'@
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'config.local.toml'), $config)
    Test-PreviousData $script:oldExe
}

function Test-CorruptUpgrade([string] $newSetup) {
    $corrupt = Join-Path $dir 'corrupt.7z'
    [IO.File]::WriteAllText($corrupt, 'synthetic corrupt package')
    if ((Invoke-Setup $newSetup $corrupt) -eq 0) { throw 'Corrupt package was accepted.' }
    Remove-Item -LiteralPath $corrupt
    if ((Get-FileHash -Algorithm SHA256 $script:oldExe).Hash -ine $oldExeHash) { throw 'Failed upgrade changed the old executable.' }
    Test-PreviousData $script:oldExe
}
