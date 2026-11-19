$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:PSModulePath = (Join-Path $PSHOME 'Modules')
$root = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Windows AutoSetup'
$stateFile = Join-Path $root 'state.json'
$taskName = 'WindowsAutoSetup.Resume'
$state = $null
$current = $null
$lock = $null
$reboot = $false
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 6 }
$plain = [Text.UTF8Encoding]::new($false)
$diagnostic = @{ Code = 'OperationFailed' }

function Assert-PlainPath([string]$Path) {
    for ($item = $Path; $item; $item = Split-Path $item -Parent) {
        if ((Test-Path -LiteralPath $item) -and
            ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Reparse point refused.'
        }
    }
}

function Write-Json([string]$Path, $Value) {
    $tmp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $bytes = $plain.GetBytes((ConvertTo-Json -InputObject $Value -Depth 20))
    $stream = [IO.File]::Open($tmp, 'CreateNew', 'Write', 'None')
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) }
    else { [IO.File]::Move($tmp, $Path) }
}

function Save-State { Write-Json $stateFile $state }

function Write-Event([string]$Event, [string]$Code = '') {
    $stage = if ($null -ne $current) { $current.Name } else { 'Engine' }
    $attempt = if ($null -ne $current) { $current.Attempts } else { 0 }
    $line = '{0:o} {1} {2} attempt={3} {4}' -f [DateTime]::UtcNow,$stage,$Event,$attempt,$Code
    [IO.File]::AppendAllText((Join-Path $root 'installation.log'), $line + [Environment]::NewLine, $plain)
}

function Assert-Hash([string]$Path, [string]$Hash) {
    if ($Hash -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash -ne $Hash) { throw 'Hash mismatch.' }
}

function Get-Area([string]$Area) {
    switch ($Area) {
        Driver { 'Drivers' }
        App { 'Apps' }
        Faceit { 'Apps/FACEIT' }
        Dev { 'DevTools/Installers' }
        default { throw 'Unsupported package area.' }
    }
}

function Copy-PinnedFile($Source, $Destination, [string]$Relative, [string]$Hash) {
    if ($Relative -notmatch '^[^:*/?"<>|\\/]+([\\/][^:*/?"<>|\\/]+)*$' -or
        ($Relative -split '[\\/]') -match '(^\.\.?$|[. ]$|[\x00-\x1F])') { throw 'Invalid relative path.' }
    $from = [IO.Path]::GetFullPath((Join-Path $Source $Relative))
    $to = [IO.Path]::GetFullPath((Join-Path $Destination $Relative))
    if (-not $from.StartsWith($Source + '\', 'OrdinalIgnoreCase') -or
        -not $to.StartsWith($Destination + '\', 'OrdinalIgnoreCase')) { throw 'Path escaped package area.' }
    Assert-PlainPath $from
    Assert-PlainPath $to
    Assert-Hash $from $Hash
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent)
    Copy-Item -LiteralPath $from -Destination $to -Force
    Assert-Hash $to $Hash
    return $to
}

function Assert-Detection($Package) {
    if ($Package.DetectPath -notmatch '^(PF|PF86|WIN)/[^:*?"<>|]+$' -or
        ($Package.DetectPath -split '[\\/]') -match '(^\.\.?$|[. ]$|[\x00-\x1F])') {
        throw 'Invalid detection path.'
    }
    $null = [version]$Package.MinVersion
    if ($Package.Area -eq 'Faceit' -and $Package.Service -ne 'FACEITService') {
        throw 'FACEITService verification is required.'
    }
}

function Test-Package($Package) {
    Assert-Detection $Package
    $prefix, $relative = $Package.DetectPath -split '/', 2
    $base = switch ($prefix) { PF { $env:ProgramFiles }; PF86 { [Environment]::GetFolderPath('ProgramFilesX86') }; WIN { $env:SystemRoot } }
    $path = Join-Path $base $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    Assert-PlainPath $path
    $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($path)
    $installed = [version]::new($version.FileMajorPart,$version.FileMinorPart,$version.FileBuildPart,$version.FilePrivatePart)
    if ($installed -lt [version]$Package.MinVersion) { return $false }
    if ($Package.Service) { return [bool](Get-Service -Name $Package.Service -ErrorAction SilentlyContinue) }
    return $true
}

function Test-PendingReboot {
    $wu = New-Object -ComObject Microsoft.Update.SystemInfo
    return ($wu.RebootRequired -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
        (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
        [bool](Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' PendingFileRenameOperations -ErrorAction SilentlyContinue))
}

function Invoke-Installer([string]$File, [string]$Arguments) {
    $params = @{ FilePath = $File; Wait = $true; PassThru = $true; WorkingDirectory = (Split-Path $File -Parent) }
    if ($Arguments) { $params.ArgumentList = $Arguments }
    return (Start-Process @params).ExitCode
}

function Invoke-Packages([string]$Area) {
    $packages = @($profile.Packages | Where-Object Area -eq $Area)
    for ($index = [int]$current.Cursor; $index -lt $packages.Count; $index++) {
        $package = $packages[$index]
        if (-not (Test-Package $package)) {
            if ($current.Verify) { $diagnostic.Code = 'PackageVerification'; throw 'Package missing after reboot.' }
            if (Test-PendingReboot) { return 'Reboot' }
            $base = Join-Path $root ('Payload/' + $state.Payload + '/' + $package.Id)
            $path = Join-Path $base $package.File
            Assert-Hash $path $package.Sha256
            if ($package.PSObject.Properties['Files'] -and $package.Files) {
                foreach ($file in $package.Files.PSObject.Properties) {
                    Assert-Hash (Join-Path $base $file.Name) $file.Value
                }
            }
            if ($package.Kind -ne 'INF' -and (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') {
                $diagnostic.Code = 'InvalidSignature'; throw 'Invalid installer signature.'
            }
            $system = [Environment]::SystemDirectory
            $diagnostic.Code = 'InstallerFailed'
            $code = switch ($package.Kind) {
                MSI { Invoke-Installer (Join-Path $system 'msiexec.exe') ('/i "{0}" /qn /norestart {1}' -f $path,$package.Arguments) }
                INF { Invoke-Installer (Join-Path $system 'pnputil.exe') ('/add-driver "{0}" /install' -f $path) }
                EXE { Invoke-Installer $path $package.Arguments }
            }
            Write-Event 'InstallerExit' ('Exit=' + $code)
            if ($code -notin 0,1641,3010) { throw 'Installer failed.' }
            if ($code -in 1641,3010 -or (Test-PendingReboot)) {
                $current.Verify = $true
                return 'Reboot'
            }
            if (-not (Test-Package $package)) {
                $diagnostic.Code = 'PackageVerification'; throw 'Package verification failed.'
            }
        }
        $current.Cursor = $index + 1
        $current.Verify = $false
        Save-State
    }
    if (Test-PendingReboot) { return 'Reboot' }
    return 'Done'
}

function Invoke-WindowsUpdate {
    $diagnostic.Code = 'WindowsUpdate'
    if (Test-PendingReboot) { return 'Reboot' }
    $session = New-Object -ComObject Microsoft.Update.Session
    $session.ClientApplicationID = 'Windows AutoSetup'
    $searcher = $session.CreateUpdateSearcher()
    $searcher.Online = $true
    for ($pass = 0; $pass -lt 5; $pass++) {
        $found = $searcher.Search('IsInstalled=0 and IsHidden=0 and BrowseOnly=0')
        if ($found.ResultCode -ne 2) { throw 'Update search failed.' }
        $updates = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $found.Updates) {
            if ($update.Title -match '(?i)\bPreview\b|\u043f\u0440\u0435\u0434\u0432\u0430\u0440\u0438\u0442\u0435\u043b\u044c\u043d') { continue }
            if ($update.InstallationBehavior.CanRequestUserInput) { throw 'Interactive update requires manual resolution.' }
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            $null = $updates.Add($update)
            if ($update.InstallationBehavior.Impact -eq 2) {
                $updates = New-Object -ComObject Microsoft.Update.UpdateColl
                $null = $updates.Add($update)
                break
            }
        }
        if ($updates.Count -eq 0) {
            if (Test-PendingReboot) { return 'Reboot' }
            return 'Done'
        }
        $installer = $session.CreateUpdateInstaller()
        if ($installer.IsBusy) { throw 'Update installer busy.' }
        if ($installer.RebootRequiredBeforeInstallation) { return 'Reboot' }
        $download = $session.CreateUpdateDownloader()
        $download.Updates = $updates
        if ($download.Download().ResultCode -ne 2) { throw 'Update download failed.' }
        $installer.Updates = $updates
        $installer.AllowSourcePrompts = $false
        $result = $installer.Install()
        Write-Event 'UpdateResult' ('Result={0};HResult={1}' -f $result.ResultCode,$result.HResult)
        if ($result.ResultCode -ne 2) { throw 'Update installation failed.' }
        for ($index = 0; $index -lt $updates.Count; $index++) {
            if ($result.GetUpdateResult($index).ResultCode -ne 2) { throw 'Update item failed.' }
        }
        if ($result.RebootRequired -or (Test-PendingReboot)) { return 'Reboot' }
    }
    throw 'Update pass limit reached.'
}

function Set-Value([string]$Path, [string]$Name, $Value, [string]$Type, [bool]$Apply) {
    if ($Apply) {
        if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
        $null = New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $Type -Force
    }
    if ((Get-ItemPropertyValue -Path $Path -Name $Name) -ne $Value) { throw 'Setting differs.' }
}

function Set-UserSettings([bool]$Apply) {
    $diagnostic.Code = 'WindowsSettings'
    $theme = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    Set-Value $theme AppsUseLightTheme 0 DWord $Apply
    Set-Value $theme SystemUsesLightTheme 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' TaskbarAl 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' ShowTaskViewButton 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search' SearchboxTaskbarMode 1 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' Enabled 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' TailoredExperiencesWithDiagnosticDataEnabled 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' SystemPaneSuggestionsEnabled 0 DWord $Apply
    Set-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' AllowTelemetry 1 DWord $Apply
    Set-Value 'HKCU:\System\GameConfigStore' GameDVR_Enabled 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' AppCaptureEnabled 0 DWord $Apply
    Set-Value 'HKCU:\Software\Microsoft\GameBar' UseNexusForGameBarEnabled 0 DWord $Apply
    Set-Value 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' AllowGameDVR 0 DWord $Apply
    foreach ($name in 'MouseSpeed','MouseThreshold1','MouseThreshold2') {
        Set-Value 'HKCU:\Control Panel\Mouse' $name '0' String $Apply
    }
    if ($Apply) {
        $languages = New-WinUserLanguageList 'en-US'
        $languages.Add('ru-RU')
        Set-WinUserLanguageList $languages -Force
        Set-Culture 'ru-RU'
        Set-TimeZone -Id $profile.TimeZone
    }
    if (((Get-WinUserLanguageList).LanguageTag -join ',') -ne 'en-US,ru-RU' -or
        (Get-TimeZone).Id -ne $profile.TimeZone -or
        (Get-ItemPropertyValue 'HKCU:\Control Panel\International' LocaleName) -ne 'ru-RU') { throw 'Locale verification failed.' }
    $power = Join-Path ([Environment]::SystemDirectory) 'powercfg.exe'
    if ($Apply) {
        foreach ($name in 'monitor-timeout-ac','monitor-timeout-dc','standby-timeout-ac','standby-timeout-dc') {
            & $power /change $name 0 | Out-Null
            if ($LASTEXITCODE) { throw 'Power setting failed.' }
        }
        foreach ($kind in '/setacvalueindex','/setdcvalueindex') {
            & $power $kind SCHEME_CURRENT SUB_SLEEP HYBRIDSLEEP 0 | Out-Null
            if ($LASTEXITCODE) { throw 'Hybrid sleep setting failed.' }
        }
        & $power /hibernate off | Out-Null
        if ($LASTEXITCODE) { throw 'Hibernation setting failed.' }
        & $power /setactive SCHEME_CURRENT | Out-Null
        if ($LASTEXITCODE) { throw 'Power scheme activation failed.' }
    }
    $powerKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
    if ((Get-ItemPropertyValue $powerKey HibernateEnabled) -ne 0) { throw 'Hibernation verification failed.' }
    $sleep = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
    foreach ($query in @(
        @{ Group = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e' },
        @{ Group = $sleep; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da' },
        @{ Group = $sleep; Setting = '94ac6d29-73ce-41a6-809f-6363ba21b47e' }
    )) {
        $output = & $power /qh SCHEME_CURRENT $query.Group $query.Setting
        $values = @($output | Select-String '0x[0-9a-fA-F]{8}' | Select-Object -Last 2)
        if ($LASTEXITCODE -or $values.Count -ne 2 -or @($values | Where-Object { $_.Matches.Value -ne '0x00000000' }).Count) {
            throw 'Power setting verification failed.'
        }
    }
}

function Update-Startup([bool]$Restore) {
    $diagnostic.Code = 'Startup'
    $backup = Join-Path $root 'startup-backup.json'
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $allow = @{ Steam = 'steam.exe'; Discord = 'update.exe'; TelegramDesktop = 'telegram.exe' }
    if ($Restore) {
        if (-not (Test-Path -LiteralPath $backup)) { return }
        foreach ($entry in (Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json).Entries) {
            if ($allow.ContainsKey($entry.Name) -and -not (Get-ItemProperty -LiteralPath $path -Name $entry.Name -ErrorAction SilentlyContinue)) {
                $null = New-ItemProperty -LiteralPath $path -Name $entry.Name -Value $entry.Value -PropertyType $entry.Type
            }
        }
        return
    }
    if (-not $profile.Startup -or -not (Test-Path -LiteralPath $path)) { return 'Skip' }
    $key = Get-Item -LiteralPath $path
    if (-not (Test-Path -LiteralPath $backup)) {
        $entries = @(
            foreach ($name in $key.GetValueNames()) {
                if (-not $allow.ContainsKey($name)) { continue }
                $value = $key.GetValue($name, '', 'DoNotExpandEnvironmentNames')
                if ([string]$value -notmatch ('(?i)\\' + [regex]::Escape($allow[$name]) + '("| |$)')) { continue }
                if ($name -eq 'Discord' -and [string]$value -notmatch '(?i)\\Discord\\Update\.exe') { continue }
                $type = [string]$key.GetValueKind($name)
                if ($type -in 'String','ExpandString') { @{ Name = $name; Value = $value; Type = $type } }
            }
        )
        Write-Json $backup @{ Entries = $entries }
    }
    foreach ($entry in (Get-Content -LiteralPath $backup -Raw | ConvertFrom-Json).Entries) {
        if ($key.GetValue($entry.Name, '', 'DoNotExpandEnvironmentNames') -eq $entry.Value) {
            Remove-ItemProperty -LiteralPath $path -Name $entry.Name
            if ($key.GetValueNames() -contains $entry.Name) { throw 'Startup cleanup verification failed.' }
        }
    }
    return 'Done'
}

function Invoke-DevTools {
    $diagnostic.Code = 'DevelopmentTools'
    $allowed = @('Git.Git','OpenJS.NodeJS.LTS','Python.Python.3.13','Docker.DockerDesktop','Gyan.FFmpeg','yt-dlp.yt-dlp','Canonical.Ubuntu.2404')
    if ($profile.Dev.Count -eq 0) { return 'Skip' }
    $app = Get-AppxPackage Microsoft.DesktopAppInstaller | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $app) { throw 'Microsoft App Installer is required.' }
    $winget = Join-Path $app.InstallLocation 'winget.exe'
    if ((Get-AuthenticodeSignature -LiteralPath $winget).Status -ne 'Valid') { throw 'Invalid WinGet signature.' }
    $wsl = Join-Path ([Environment]::SystemDirectory) 'wsl.exe'
    for ($i = [int]$current.Cursor; $i -lt $profile.Dev.Count; $i++) {
        $id = [string]$profile.Dev[$i]
        if (Test-PendingReboot) { return 'Reboot' }
        if ($id -eq 'WSL') {
            $enabled = (Get-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux).State -eq 'Enabled'
            $platform = (Get-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform).State -eq 'Enabled'
            if (-not ($enabled -and $platform)) {
                $features = Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Windows-Subsystem-Linux,VirtualMachinePlatform -All -NoRestart
                if ($features.RestartNeeded -or (Test-PendingReboot)) { return 'Reboot' }
            }
            & $wsl --update --web-download *> $null
            if ($LASTEXITCODE) { throw 'WSL update failed.' }
            & $wsl --set-default-version 2 *> $null
            if ($LASTEXITCODE) { throw 'WSL2 default configuration failed.' }
        } else {
            if ($id -notin $allowed) { throw 'Unknown WinGet package.' }
            $list = @('list','--id',$id,'--exact','--source','winget','--accept-source-agreements','--disable-interactivity')
            & $winget @list *> $null
            if ($LASTEXITCODE -ne 0) {
                $install = @('install','--id',$id,'--exact','--source','winget','--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
                & $winget @install *> $null
                $result = $LASTEXITCODE
                Write-Event 'WinGetExit' ('Exit=' + $result)
                if (Test-PendingReboot) { return 'Reboot' }
                if ($result -ne 0) { throw 'WinGet install failed.' }
                & $winget @list *> $null
                if ($LASTEXITCODE) { throw 'WinGet verification failed.' }
            }
        }
        $current.Cursor = $i + 1
        Save-State
    }
    return 'Done'
}

function Invoke-Stage([string]$Stage) {
    $diagnostic.Code = 'OperationFailed'
    switch ($Stage) {
        Settings { Set-UserSettings $true; 'Done' }
        Drivers { Invoke-Packages Driver }
        WindowsUpdate {
            for ($retry = 1; $retry -le 3; $retry++) {
                try { return Invoke-WindowsUpdate }
                catch {
                    if ($retry -eq 3) { throw }
                    Write-Event 'Retry' ('UpdateAttempt=' + $retry)
                    Start-Sleep -Seconds 5
                }
            }
        }
        Apps { Invoke-Packages App }
        Faceit {
            if (@($profile.Packages | Where-Object Area -eq Faceit).Count -eq 0) { return 'Skip' }
            $diagnostic.Code = 'FaceitPrerequisites'
            if (Test-PendingReboot) { return 'Reboot' }
            if (-not (Confirm-SecureBootUEFI) -or -not (Get-Tpm).TpmReady) { throw 'Secure Boot and TPM readiness required.' }
            if ((New-Object -ComObject Microsoft.Update.Session).CreateUpdateInstaller().IsBusy) { throw 'Update installation active.' }
            Invoke-Packages Faceit
        }
        Startup { Update-Startup $false }
        FinalVerification {
            Set-UserSettings $false
            foreach ($package in $profile.Packages | Where-Object Area -in 'Driver','App','Faceit') {
                if (-not (Test-Package $package)) { $diagnostic.Code = 'FinalPackageVerification'; throw 'Package missing.' }
            }
            'Done'
        }
        AccountWizard { 'Skip' }
        DevTools { Invoke-DevTools }
        DevPackages { Invoke-Packages Dev }
    }
}

function Get-StageDecision($Task, [string]$Boot, [string]$Action) {
    if ($Task.Status -in 'Completed','Skipped') { return 'Next' }
    if ($Task.Status -eq 'Running') { return 'Interrupted' }
    if ($Task.Status -in 'Blocked','Failed' -and $Action -ne 'Retry') { return 'Hold' }
    if ($Task.Status -eq 'WaitingForReboot' -and $Task.Boot -eq $Boot) { return 'Hold' }
    if ($Task.Attempts -ge 12 -or $Task.Reboots -ge 8) { return 'Limit' }
    if ($Task.Status -notin 'Pending','Blocked','Failed','WaitingForReboot') { return 'Hold' }
    return 'Run'
}

function Get-TaskNames([string]$Mode) {
    if ($Mode -eq 'Dev') { return 'DevTools','DevPackages' }
    if ($Mode -eq 'Post') { return 'Settings','Drivers','WindowsUpdate','Apps','Faceit','Startup','FinalVerification','AccountWizard' }
    throw 'Unknown pipeline.'
}

function Install-Run($Request) {
    if ($Request.Mode -notin 'Dev','Post' -or $sid -ne $Request.Sid) { throw 'User or run mode mismatch.' }
    if (Test-Path -LiteralPath $stateFile) {
        $prior = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($prior.Schema -ne 1 -or $prior.UserSid -ne $sid -or $prior.Payload -notmatch '^[a-f0-9]{32}$' -or
            @($prior.Tasks | Where-Object Status -notin 'Completed','Skipped').Count) {
            $diagnostic.Code = 'ExistingRun'; throw 'An unfinished run already exists.'
        }
        Write-Json (Join-Path $root ("run-" + $prior.Payload + ".json")) $prior
    }
    $source = [string]$Request.Source
    Assert-PlainPath $source
    $selected = Join-Path $source 'Config/profile.json'
    Assert-PlainPath $selected
    Assert-Hash $selected $Request.ProfileHash
    if ((Get-Item -LiteralPath $selected).Length -gt 2MB) { throw 'Profile too large.' }
    $payload = [guid]::NewGuid().ToString('N')
    $profileFile = Join-Path $root "profile-$payload.json"
    Copy-Item -LiteralPath $selected -Destination $profileFile
    Assert-Hash $profileFile $Request.ProfileHash
    $config = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($config.Packages.Count -gt 100 -or $config.Dev.Count -gt 20 -or
        $config.Reboot -isnot [bool] -or $config.Startup -isnot [bool]) { throw 'Invalid profile.' }
    $ids = @{}
    $areas = if ($Request.Mode -eq 'Dev') { @('Dev') } else { @('Driver','App','Faceit') }
    foreach ($package in $config.Packages | Where-Object Area -in $areas) {
        if ($package.Id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,47}$' -or $ids.ContainsKey($package.Id) -or
            $package.Kind -notin 'INF','MSI','EXE' -or [IO.Path]::GetExtension($package.File) -ne ".$($package.Kind)" -or
            ($package.Kind -eq 'INF' -and $package.Area -ne 'Driver') -or
            ($package.Area -eq 'App' -and ($package.File -match '(^|[\\/])FACEIT([\\/]|[-_. ])' -or $package.Service -eq 'FACEITService')) -or
            ($package.Kind -eq 'EXE' -and [string]::IsNullOrWhiteSpace($package.Arguments))) { throw 'Malformed package.' }
        $ids[$package.Id] = $true
        Assert-Detection $package
        $area = [IO.Path]::GetFullPath((Join-Path $source (Get-Area $package.Area)))
        $target = [IO.Path]::GetFullPath((Join-Path $root ('Payload/' + $payload + '/' + $package.Id)))
        $path = Copy-PinnedFile $area $target $package.File $package.Sha256
        if ($package.Kind -ne 'INF' -and (Get-AuthenticodeSignature -LiteralPath $path).Status -ne 'Valid') {
            throw 'Invalid installer signature.'
        }
        if ($package.PSObject.Properties['Files'] -and $package.Files) {
            foreach ($file in $package.Files.PSObject.Properties) {
                $null = Copy-PinnedFile $area $target $file.Name $file.Value
            }
        }
    }
    if ($config.Dev -contains 'Canonical.Ubuntu.2404' -and
        (($config.Dev -join ',') -notmatch '(^|,)WSL(,.*)?,Canonical\.Ubuntu\.2404(,|$)')) {
        throw 'Select WSL2 before Ubuntu.'
    }
    $installed = Join-Path $root 'WindowsAutoSetup.exe'
    $agent = Join-Path $root 'Worker.ps1'
    if ($Request.Mode -eq 'Dev') {
        Assert-PlainPath $Request.Exe
        Assert-Hash $Request.Exe $Request.ExeHash
        if ($Request.Exe -ne $installed) { Copy-Item -LiteralPath $Request.Exe -Destination $installed -Force }
        Assert-Hash $installed $Request.ExeHash
        [IO.File]::WriteAllBytes($agent, $workerBytes)
    } elseif ($source -ne (Join-Path $root 'Seed') -or -not (Test-Path -LiteralPath $agent)) {
        throw 'Post-install seed is missing.'
    }
    $names = Get-TaskNames $Request.Mode
    $new = [pscustomobject]@{
        Schema = 1; UserSid = $sid; Mode = $Request.Mode; Created = [DateTime]::UtcNow.ToString('o')
        ProfileHash = (Get-FileHash -LiteralPath $profileFile).Hash; Payload = $payload
        Tasks = @($names | ForEach-Object {
            [pscustomobject]@{ Name = $_; Status = 'Pending'; Attempts = 0; Reboots = 0; Cursor = 0; Verify = $false
                Boot = ''; Start = ''; End = ''; Code = '' }
        })
    }
    $powershell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
    $literal = $agent.Replace("'","''")
    $resume = '$request=[pscustomobject]@{Action=''Resume''}; & ([scriptblock]::Create([IO.File]::ReadAllText(''' + $literal + ''')))'
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($resume))
    $action = New-ScheduledTaskAction -Execute $powershell -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encoded" -WorkingDirectory ([Environment]::SystemDirectory)
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $sid
    $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Json $stateFile $new
}

try {
    Assert-PlainPath $root
    $null = New-Item -ItemType Directory -Path $root -Force
    foreach ($path in $stateFile,(Join-Path $root 'run.lock'),(Join-Path $root 'installation.log'),
        (Join-Path $root 'Payload'),(Join-Path $root 'WindowsAutoSetup.exe'),(Join-Path $root 'Worker.ps1'),(Join-Path $root 'startup-backup.json')) {
        Assert-PlainPath $path
    }
    try { $lock = [IO.File]::Open((Join-Path $root 'run.lock'),'OpenOrCreate','ReadWrite','None') }
    catch [IO.IOException] { exit 4 }
    if ($request.Action -eq 'Start') { Install-Run $request }
    if (-not (Test-Path -LiteralPath $stateFile)) { exit 0 }
    $state = Get-Content -LiteralPath $stateFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.Schema -ne 1 -or $state.UserSid -ne $sid -or $state.Payload -notmatch '^[a-f0-9]{32}$') {
        throw 'State owner or schema mismatch.'
    }
    $profileFile = Join-Path $root ("profile-" + $state.Payload + ".json")
    Assert-PlainPath $profileFile
    Assert-Hash $profileFile $state.ProfileHash
    $profile = Get-Content -LiteralPath $profileFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($request.Action -eq 'Restore') { Update-Startup $true; Write-Event 'StartupRestored'; exit 0 }
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToUniversalTime().ToString('o')
    foreach ($current in $state.Tasks) {
        $decision = Get-StageDecision $current $boot $request.Action
        if ($decision -eq 'Next') { continue }
        if ($decision -eq 'Interrupted') {
            $current.Status = 'Blocked'; $current.Code = 'Interrupted'
            Save-State
            Write-Event 'Blocked' 'Interrupted'
            $decision = Get-StageDecision $current $boot $request.Action
        }
        if ($decision -eq 'Hold') { exit 0 }
        if ($decision -eq 'Limit') {
            $current.Status = 'Blocked'; $current.Code = 'AttemptLimit'
            Save-State
            Write-Event 'Blocked' 'AttemptLimit'
            exit 0
        }
        $current.Attempts++
        $current.Status = 'Running'; $current.Start = [DateTime]::UtcNow.ToString('o'); $current.End = ''; $current.Code = ''
        Save-State
        Write-Event 'Started'
        $outcome = Invoke-Stage $current.Name
        $current.End = [DateTime]::UtcNow.ToString('o')
        if ($outcome -eq 'Reboot') {
            $current.Reboots++
            $current.Boot = $boot
            $current.Status = 'WaitingForReboot'
            $current.Code = 'RestartRequired'
            Save-State
            Write-Event 'WaitingForReboot'
            $reboot = $profile.Reboot
            break
        }
        if ($outcome -notin 'Done','Skip') { throw 'Invalid task outcome.' }
        $current.Status = if ($outcome -eq 'Done') { 'Completed' } else { 'Skipped' }
        Save-State
        Write-Event $current.Status
    }
    if (@($state.Tasks | Where-Object Status -notin 'Completed','Skipped').Count -eq 0) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {
    if ($null -ne $current -and $current.Status -eq 'Running') {
        $current.Status = if ($current.Name -in 'WindowsUpdate','Faceit','FinalVerification') { 'Blocked' } else { 'Failed' }
        $current.End = [DateTime]::UtcNow.ToString('o'); $current.Code = $diagnostic.Code
        Save-State
    }
    if ($null -ne $lock) { Write-Event 'Error' $diagnostic.Code }
    exit 2
} finally {
    if ($null -ne $lock) { $lock.Dispose() }
}
if ($reboot) {
    & (Join-Path ([Environment]::SystemDirectory) 'shutdown.exe') /r /t 0
    if ($LASTEXITCODE) { exit 3 }
}
exit 0
