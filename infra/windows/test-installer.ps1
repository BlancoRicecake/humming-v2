param(
    [Parameter(Mandatory=$true)][string]$PayloadDir,
    [Parameter(Mandatory=$true)][string]$Iscc,
    [Parameter(Mandatory=$true)][string]$TestRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$qaRoot = [IO.Path]::GetFullPath($TestRoot)
if (-not $qaRoot.StartsWith($repoRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Installer test must stay inside the workspace'
}
if (Test-Path -LiteralPath $qaRoot) { throw 'Choose a fresh test directory' }
$scheme = 'humtrack-release-qa'
$schemeKey = 'HKCU:\Software\Classes\' + $scheme
if (Test-Path -LiteralPath $schemeKey) { throw 'QA scheme already exists; do not overwrite it' }
New-Item -ItemType Directory -Path $qaRoot | Out-Null
$installDir = Join-Path $qaRoot 'install 한글 space'
$proofDir = Join-Path $qaRoot 'user-work'
New-Item -ItemType Directory -Path $proofDir | Out-Null
$saved = Join-Path $proofDir 'saved.humtrack'
Set-Content -LiteralPath $saved -Value 'QA saved music sentinel' -Encoding utf8
$savedHash = (Get-FileHash -LiteralPath $saved).Hash
$realProtocol = 'HKCU:\Software\Classes\humtrack\shell\open\command'
$before = if (Test-Path -LiteralPath $realProtocol) { (Get-Item -LiteralPath $realProtocol).GetValue('') } else { $null }
$compileArgs = @('/Qp', ('/DPayloadDir=' + [IO.Path]::GetFullPath($PayloadDir)),
    ('/DOutputDir=' + $qaRoot), '/DAppVersion=1.0.13', '/DAppBuild=43',
    ('/DAppIcon=' + (Join-Path $repoRoot 'mobile\windows\runner\resources\app_icon.ico')),
    '/DProtocolScheme=humtrack-release-qa', '/DInstallerId=06961AC4-AFF0-42F2-A716-716FEC646DBC',
    '/DQAInstaller=1', (Join-Path $repoRoot 'infra\windows\humtrack.iss'))
& $Iscc @compileArgs
if ($LASTEXITCODE -ne 0) { throw 'QA installer did not compile' }
$setup = (Get-ChildItem -LiteralPath $qaRoot -Filter '*-setup.exe').FullName
$installArgs = @('/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART',
    ('/DIR="' + $installDir + '"'), ('/LOG="' + (Join-Path $qaRoot 'install.log') + '"'))
$installed = $false
try {
    $p = Start-Process -FilePath $setup -ArgumentList $installArgs -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw ('Install failed: ' + $p.ExitCode) }
    $installed = $true
    if (-not (Test-Path -LiteralPath (Join-Path $installDir 'HumTrack.exe'))) { throw 'Executable missing' }
    $command = (Get-Item -LiteralPath ($schemeKey + '\shell\open\command')).GetValue('')
    if ($command -ne ('"' + $installDir + '\HumTrack.exe" "%1"')) { throw 'Quoted callback command is wrong' }
    $localFile = Join-Path $installDir 'user-created.humtrack'
    Set-Content -LiteralPath $localFile -Value 'QA untracked music sentinel' -Encoding utf8
    $localHash = (Get-FileHash -LiteralPath $localFile).Hash
    $p = Start-Process -FilePath $setup -ArgumentList $installArgs -WindowStyle Hidden -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw ('Reinstall failed: ' + $p.ExitCode) }
    if ((Get-FileHash -LiteralPath $localFile).Hash -ne $localHash) { throw 'Reinstall changed user file' }
} finally {
    if ($installed) {
        $p = Start-Process -FilePath (Join-Path $installDir 'unins000.exe') -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART') -WindowStyle Hidden -Wait -PassThru
        if ($p.ExitCode -ne 0) { throw ('Uninstall failed: ' + $p.ExitCode) }
    }
}
if (Test-Path -LiteralPath (Join-Path $installDir 'HumTrack.exe')) { throw 'Uninstall left the executable' }
if (Test-Path -LiteralPath $schemeKey) { throw 'Uninstall left the owned QA protocol' }
if ((Get-FileHash -LiteralPath $saved).Hash -ne $savedHash) { throw 'User work was changed' }
if ((Get-FileHash -LiteralPath $localFile).Hash -ne $localHash) { throw 'Uninstall removed untracked user file' }
$after = if (Test-Path -LiteralPath $realProtocol) { (Get-Item -LiteralPath $realProtocol).GetValue('') } else { $null }
if ($before -ne $after) { throw 'Real HumTrack protocol changed' }
$proof = @{ install=$true; reinstall=$true; uninstall=$true; koreanPath=$true;
    ownProtocolRemoved=$true; realProtocolPreserved=$true; userFileHashesPreserved=$true;
    cleanMachineTested=$false; oauthAccountTested=$false; signed=$false }
$proof | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $qaRoot 'result.json') -Encoding utf8
$proof | ConvertTo-Json
