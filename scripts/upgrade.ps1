$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted') { throw 'Upgrade checks require a GitHub-hosted runner.' }
$oldSetupHash = '37c8153126a2eaeb079f31e16a63297d66e84297a2f33c557212c462c5e34a93'
$oldPackageHash = '60298757acd8c5915dce5d236f2e27e5c9b2ff83bb57b4e343569c8ee277c3dd'
$oldExeHash = '49ce280d61790d40654267b9796a5f9cc2b5765021db61bd920706889606c82a'
$oldSetupUrl = 'https://github.com/toshodin/dendrokeeper-releases/releases/download/v0.1.0/DendroKeeper-0.1.0.0-win-x64-setup.exe'
$oldPackageUrl = 'https://dendro-keeper.com/downloads/v0.1.0/DendroKeeper-0.1.0.0-win-x64.7z'
$oldShortcut = 'Dendro Keeper.lnk'
if ($tag -ceq 'v0.1.2') {
    $oldSetupUrl = 'https://github.com/toshodin/dendrokeeper-releases/releases/download/v0.1.1/CallToMind-0.1.1.0-win-x64-setup.exe'
    $oldPackageUrl = 'https://calltomind.app/downloads/v0.1.1/CallToMind-0.1.1.0-win-x64.7z'
    $oldSetupHash = 'd32dec1942ab93988bd752a851f35cf4d9511cdf8c442bca19969dd47ae85f85'
    $oldPackageHash = '5af0901b7ca27ad3dfcffc1ddf97ee5cc47c8fb4b117d04c6c7f4a5aab1e0bd0'
    $oldExeHash = 'f9d9c1a13307f6b4877709b874122d01ce0af7fbba723870bfad293d9365ffb8'
    $oldShortcut = 'Call to Mind.lnk'
} elseif ($tag -ceq 'v0.1.3') {
    $oldSetupUrl = 'https://github.com/toshodin/dendrokeeper-releases/releases/download/v0.1.2/CallToMind-0.1.2.0-win-x64-setup.exe'
    $oldPackageUrl = 'https://calltomind.app/downloads/v0.1.2/CallToMind-0.1.2.0-win-x64.7z'
    $oldSetupHash = '8fcb7510a3529a6f9b9c001d0f1c99d730362d439be960a86594be63bc57aa5f'
    $oldPackageHash = '8d8cd29891e9351f3012b88448112ef07c14d3902d0f4ff1ac5051a41685f792'
    $oldExeHash = '3f0555f4eb328a1c61fd01443de6bf5310a434aec50690a4b7e7132dcdc3a733'
    $oldShortcut = 'Call to Mind.lnk'
} elseif ($tag -cne 'v0.1.1') { throw 'Select and pin the previous release before running this upgrade.' }
$syntheticHome = Join-Path $dir 'synthetic-data'
$customNotes = Join-Path $dir 'custom-notes'
$credentialTarget = 'model-key:local@meeting-capture'
$notePath = Join-Path $customNotes 'meetings/2026-11-20-synthetic-upgrade-meeting/summary.md'
$recordedAudio = Join-Path $syntheticHome 'recordings/2026-11-20_090000_000/mic.wav'
$pointer = Join-Path $env:USERPROFILE '.dendro-keeper-folder'
$env:MEETING_CAPTURE_FAKE_CONTROL = Join-Path $dir 'control'
$env:MEETING_CAPTURE_FAKES = '1'
$env:MEETING_CAPTURE_INSTANCE = 'CallToMindUpgradeSmoke'
$env:MEETING_CAPTURE_FAKE_EVENT_PORT = '0'
Remove-Item Env:MEETING_CAPTURE_HOME -ErrorAction SilentlyContinue

function Invoke-Setup([string] $file, [string] $package) {
    $process = Start-Process -FilePath $file -ArgumentList @('/S', "--package-file=`"$package`"") -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Test-PreviousData([string] $executable, [switch] $workspace) {
    if ((Get-FileHash -LiteralPath $recordedAudio).Hash -cne $script:recordedHash) { throw 'Synthetic microphone recording changed.' }
    $credential = cmdkey.exe "/list:$credentialTarget" | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $credential.Contains($credentialTarget) -or -not $credential.Contains('User: model-key:local')) { throw 'Synthetic Windows model credential missing.' }
    if ([IO.File]::ReadAllText($notePath) -cne 'Synthetic summary') { throw 'The custom meeting note changed.' }
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
        if ($settings.delivery_folder -ine $customNotes -or $settings.retention_days -ne 12 -or $settings.recordings_in_use -ine (Join-Path $syntheticHome 'recordings')) { throw 'Existing settings or data pointer were not used.' }
        $models = Invoke-RestMethod -Uri "$origin/api/models" -Headers $headers -TimeoutSec 10
        if (@($models.endpoints | Where-Object { $_.id -ceq 'local' -and $_.model -ceq 'synthetic-model' }).Count -ne 1) { throw 'Existing model settings were not used.' }
        if ((Get-Content -LiteralPath (Join-Path $env:HF_HOME 'model-sentinel.txt') -Raw).Trim() -cne 'synthetic model cache') { throw 'Model cache sentinel changed.' }
        if ($workspace -and $tag -ceq 'v0.1.3' -and ($settings.reduce_bleed -isnot [bool] -or $settings.reduce_bleed)) { throw 'Echo reduction must start off after upgrade.' }
        if ($workspace) {
            $uri = "$origin/api/workspace"
            $scope = (Invoke-RestMethod -Uri $uri -Headers $headers).engagements
            if (@($scope).Count -ne 1) { throw 'Expected one Solo engagement.' }
            $projectName = 'Synthetic upgrade project'
            $body = @{action='add_project'; engagement=$scope[0].id; name=$projectName} | ConvertTo-Json
            $created = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body
            $projects = (Invoke-RestMethod -Uri $uri -Headers $headers).engagements[0].projects
            if (-not $created.id -or @($projects | Where-Object { $_.id -ceq $created.id -and $_.name -ceq $projectName }).Count -ne 1) { throw 'Upgraded workspace failed to store its project.' }
            $body = @{action='keep'; engagement=$scope[0].id; project=$created.id; meeting='2026-11-20_090000_000'; kind='task'; text='Review the sample'; quote='Check the sample before release.'} | ConvertTo-Json
            $record = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body
            $body = @{action='project'; engagement=$scope[0].id; project=$created.id} | ConvertTo-Json
            $saved = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $body
            if (-not $record.id -or $saved.records[0].id -cne $record.id -or $saved.records[0].quote -cne 'Check the sample before release.') { throw 'Original meeting evidence missing from the project.' }
        }
        if ($tag -ceq 'v0.1.3' -and (Get-FileHash -LiteralPath $script:fixtureFile).Hash -cne $script:fixtureHash) { throw 'Encrypted synthetic credential changed.' }
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
    Invoke-WebRequest -Uri $oldSetupUrl -OutFile $oldSetup -TimeoutSec 180
    if ((Get-FileHash -Algorithm SHA256 $oldSetup).Hash -ine $oldSetupHash) { throw 'Previous setup checksum mismatch.' }
    Invoke-WebRequest -Uri $oldPackageUrl -OutFile $oldPackage -TimeoutSec 900
    if ((Get-FileHash -Algorithm SHA256 $oldPackage).Hash -ine $oldPackageHash) { throw 'Previous package checksum mismatch.' }
    if ((Invoke-Setup $oldSetup $oldPackage) -ne 0) { throw 'Previous setup failed.' }
    Remove-Item -LiteralPath $oldSetup
    if (Test-Path -LiteralPath $oldPackage) { Remove-Item -LiteralPath $oldPackage }
    $link = @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Programs')) -Recurse -File -Filter $oldShortcut)
    if ($link.Count -ne 1) { throw 'Previous shortcut missing or ambiguous.' }
    $script:oldLink = $link[0].FullName
    $script:oldExe = (New-Object -ComObject WScript.Shell).CreateShortcut($script:oldLink).TargetPath
    if ((Get-FileHash -Algorithm SHA256 $script:oldExe).Hash -ine $oldExeHash) { throw 'Previous executable checksum mismatch.' }
    New-Item -ItemType Directory -Force -Path $syntheticHome, $env:MEETING_CAPTURE_FAKE_CONTROL, (Join-Path $syntheticHome 'recordings/2026-11-20_090000_000'), (Join-Path $customNotes 'meetings/2026-11-20-synthetic-upgrade-meeting') | Out-Null
    [IO.File]::WriteAllBytes($recordedAudio, [Convert]::FromBase64String('UklGRkQAAABXQVZFZm10IBAAAAABAAEAgD4AAAB9AAACABAAZGF0YSAAAAABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAAEAAQABAA=='))
    $script:recordedHash = (Get-FileHash -LiteralPath $recordedAudio).Hash
    $env:HF_HOME = Join-Path $dir 'synthetic-models'
    New-Item -ItemType Directory -Path $env:HF_HOME | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:HF_HOME 'model-sentinel.txt'), 'synthetic model cache')
    [IO.File]::WriteAllText($pointer, "$syntheticHome`n")
    [IO.File]::WriteAllText((Join-Path $env:MEETING_CAPTURE_FAKE_CONTROL 'calendar.json'), '{"items":[]}')
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'recordings/2026-11-20_090000_000/meeting.json'), '{"title":"Synthetic upgrade meeting","source":"unsorted"}')
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'recordings/2026-11-20_090000_000/filed.json'), '{"folder":"2026-11-20-synthetic-upgrade-meeting"}')
    [IO.File]::WriteAllText($notePath, 'Synthetic summary')
    [IO.File]::WriteAllText((Join-Path (Split-Path $notePath) 'transcript.md'), 'Check the sample before release.')
    if ($tag -ceq 'v0.1.3') {
        $stores = @("$env:APPDATA/Microsoft/Credentials", "$env:LOCALAPPDATA/Microsoft/Credentials")
        $existing = @(Get-ChildItem -LiteralPath $stores -Force -File -ErrorAction SilentlyContinue | ForEach-Object FullName)
    }
    cmdkey.exe "/generic:$credentialTarget" /user:model-key:local /pass:synthetic-upgrade-test
    if ($LASTEXITCODE -ne 0) { throw 'Could not seed synthetic Windows credential.' }
    if ($tag -ceq 'v0.1.3') {
        $added = @(Get-ChildItem -LiteralPath $stores -Force -File -ErrorAction SilentlyContinue | Where-Object FullName -NotIn $existing)
        if ($added.Count -ne 1) { throw 'Could not identify the encrypted synthetic credential file.' }
        $script:fixtureFile = $added[0].FullName
        $script:fixtureHash = (Get-FileHash -LiteralPath $script:fixtureFile).Hash
    }
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
folder = __NOTES__
host = ""
root = ""
[unsorted]
folder = "synthetic"
action_log = "synthetic/actions.md"
'@
    $config = $config.Replace('__NOTES__', (ConvertTo-Json -InputObject $customNotes -Compress))
    [IO.File]::WriteAllText((Join-Path $syntheticHome 'config.local.toml'), $config)
    Test-PreviousData $script:oldExe
}

function Test-CorruptUpgrade([string] $newSetup) {
    $corrupt = Join-Path $dir 'corrupt.7z'
    [IO.File]::WriteAllText($corrupt, 'synthetic corrupt package')
    $exitCode = Invoke-Setup $newSetup $corrupt
    if ($exitCode -ne 17) { throw "Expected package verification failure 17, got $exitCode." }
    Remove-Item -LiteralPath $corrupt
    if ((Get-FileHash -Algorithm SHA256 $script:oldExe).Hash -ine $oldExeHash) { throw 'Failed upgrade changed the old executable.' }
    if (-not (Test-Path -LiteralPath $script:oldLink) -or (New-Object -ComObject WScript.Shell).CreateShortcut($script:oldLink).TargetPath -ine $script:oldExe) { throw 'Failed upgrade changed the old shortcut.' }
    Test-PreviousData $script:oldExe
}
