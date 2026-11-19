$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DiskSafety.psm1') -Force

function Invoke-Native([string]$File, [string[]]$Arguments) {
    & $File @Arguments | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$File returned $LASTEXITCODE." }
}

function Read-DeploymentPlan([string]$Root) {
    $path = Join-Path $Root 'deployment-plan.json'
    if ((Get-Item -LiteralPath $path).Length -gt 2MB) { throw 'Plan too large.' }
    $bytes = [IO.File]::ReadAllBytes($path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','') }
    finally { $sha.Dispose() }
    $entered = (Read-Host 'Enter the 20-character approval code from Windows AutoSetup').Trim()
    if ($entered -ne $digest.Substring(0,20)) { throw 'Plan approval code is incorrect.' }
    $plan = [Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json
    if ($plan.Schema -ne 1 -or $plan.User -notmatch '^[a-zA-Z][a-zA-Z0-9_-]{0,18}$' -or
        $plan.User -match '^(Administrator|Guest|DefaultAccount|WDAGUtilityAccount)$') { throw 'Invalid plan.' }
    $null = [TimeZoneInfo]::FindSystemTimeZoneById($plan.TimeZone)
    return $plan
}

function Assert-Media([string]$Root, $Plan) {
    $entries = @($Plan.Files.PSObject.Properties)
    $knownImages = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ImageManifest.json') -Raw | ConvertFrom-Json
    if ($entries.Count -lt 3 -or $entries.Count -gt 5000 -or
        -not $Plan.Files.PSObject.Properties['Images/install.swm'] -or
        -not $Plan.Files.PSObject.Properties['AutoSetup/Seed/WindowsAutoSetup.exe'] -or
        -not $Plan.Files.PSObject.Properties['AutoSetup/Seed/Config/profile.json'] -or
        $Plan.BootSha256 -notmatch '^[a-fA-F0-9]{64}$' -or
        (Get-FileHash -LiteralPath (Join-Path $Root 'sources/boot.wim')).Hash -ne $Plan.BootSha256) {
        throw 'Incomplete or invalid media manifest.'
    }
    foreach ($entry in $entries) {
        if ($entry.Name -notmatch '^(Images/install\d*\.swm|AutoSetup/Seed/[^:\\*?"<>|]+)$' -or
            ($entry.Name -split '/') -match '(^\.\.?$|^$|[. ]$|[\x00-\x1F])' -or
            $entry.Value -notmatch '^[a-fA-F0-9]{64}$' -or
            (Get-FileHash -LiteralPath (Join-Path $Root $entry.Name)).Hash -ne $entry.Value) { throw 'Invalid path or media hash.' }
    }
    $actual = @(Get-ChildItem -LiteralPath (Join-Path $Root 'Images') -File -Filter 'install*.swm')
    if ($actual.Count -ne @($entries | Where-Object Name -like 'Images/*').Count) { throw 'Unexpected SWM segments.' }
    $trusted = @($knownImages.PSObject.Properties)
    if ($trusted.Count -ne $actual.Count) { throw 'Unexpected Windows image for this WinPE.' }
    foreach ($image in $trusted) {
        $planned = $Plan.Files.PSObject.Properties[$image.Name]
        if (-not $planned -or $planned.Value -ne $image.Value) { throw 'Windows image does not match the built-in manifest.' }
    }
}

function Write-Unattend([string]$Path, $Plan) {
    $zone = [Security.SecurityElement]::Escape($Plan.TimeZone)
    $user = [Security.SecurityElement]::Escape($Plan.User)
    $xml = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <TimeZone>$zone</TimeZone>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <InputLocale>0409:00000409;0419:00000419</InputLocale>
      <SystemLocale>ru-RU</SystemLocale>
      <UILanguage>ru-RU</UILanguage>
      <UserLocale>ru-RU</UserLocale>
    </component>
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
      <OOBE>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <ProtectYourPC>3</ProtectYourPC>
      </OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add">
        <Name>$user</Name><Group>Administrators</Group>
        <Password><Value></Value><PlainText>true</PlainText></Password>
      </LocalAccount></LocalAccounts></UserAccounts>
      <FirstLogonCommands><SynchronousCommand wcm:action="add">
        <Order>1</Order>
        <Description>Start Windows AutoSetup</Description>
        <CommandLine>%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%ProgramFiles%\Windows AutoSetup\PostEntry.ps1"</CommandLine>
      </SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>
"@
    $null = [xml]$xml
    [IO.File]::WriteAllText($Path, $xml, [Text.UTF8Encoding]::new($false))
}

try {
    Assert-LabGuest
    Invoke-Native 'wpeutil.exe' @('UpdateBootInfo')
    if ((Get-ItemPropertyValue 'HKLM:\SYSTEM\CurrentControlSet\Control' 'PEFirmwareType') -ne 2) {
        throw 'Boot WinPE in UEFI mode.'
    }
    $media = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 5' |
        Where-Object { Test-Path -LiteralPath (Join-Path ($_.DeviceID + '\') 'deployment-plan.json') })
    if ($media.Count -ne 1) { throw 'Attach exactly one authorized read-only Hyper-V deployment ISO.' }
    $source = $media[0].DeviceID + '\'
    $plan = Read-DeploymentPlan $source
    Assert-Media $source $plan
    $expected = Resolve-TargetDisk $plan.Target @(Get-LiveDiskIdentities)
    Assert-LabDisk $expected
    foreach ($letter in 'S','W','R') {
        if (Get-PSDrive -Name $letter -ErrorAction SilentlyContinue) { throw 'Reserved drive letter already in use.' }
    }
    $image = Join-Path $source 'Images/install.swm'
    Write-Host "Virtual disk to erase: $($expected.Model), $($expected.Size) bytes"
    Write-Host "Serial: $($expected.Serial)  GPT GUID: $($expected.Guid)"
    Write-Host "Identifier: $($expected.UniqueId)"
    if ((Read-Host "Type ERASE $($expected.Guid) to erase this virtual disk") -cne "ERASE $($expected.Guid)") {
        throw 'Erase confirmation declined.'
    }
    $target = Resolve-TargetDisk $plan.Target @(Get-LiveDiskIdentities)
    Assert-LabDisk $target
    $live = Get-Disk -Number $target.Number
    if ($live.IsBoot -or $live.IsSystem -or $live.IsOffline -or $live.IsReadOnly) { throw 'Target disk is not writable.' }
    $checked = Get-DiskIdentity $live
    $null = Resolve-TargetDisk $plan.Target @($checked)
    $diskpart = Join-Path $env:TEMP 'autosetup-layout.txt'
    @"
select disk $($checked.Number)
clean
convert gpt
uniqueid disk id=$($expected.Guid)
create partition efi size=260
format quick fs=fat32 label=System
assign letter=S
create partition msr size=16
create partition primary
format quick fs=ntfs label=Windows
shrink desired=1536 minimum=1536
assign letter=W
create partition primary
format quick fs=ntfs label=Recovery
assign letter=R
set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac
gpt attributes=0x8000000000000001
exit
"@ | Set-Content -LiteralPath $diskpart -Encoding ASCII
    Invoke-Native 'diskpart.exe' @('/s',$diskpart)
    $after = Get-DiskIdentity (Get-Disk -Number $target.Number)
    foreach ($field in 'Guid','Serial','UniqueId','Bus','Model','Size','Style') {
        if ($after.$field -ne $target.$field) { throw 'Disk changed during partitioning.' }
    }
    $parts = @(Get-Partition -DiskNumber $target.Number | Sort-Object Offset)
    $types = @('c12a7328-f81f-11d2-ba4b-00a0c93ec93b','e3c9e316-0b5c-4db8-817d-f92df00215ae',
        'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7','de94bba4-06d1-4d40-a16a-bfd50179d6ac')
    if ($parts.Count -ne 4 -or $parts[0].Size -ne 260MB -or $parts[1].Size -ne 16MB -or
        $parts[2].Size -lt 60GB -or $parts[3].Size -lt 1400MB) { throw 'Unexpected partition layout.' }
    for ($i = 0; $i -lt 4; $i++) {
        if ([guid]$parts[$i].GptType -ne [guid]$types[$i]) { throw 'Unexpected GPT partition type.' }
    }
    foreach ($check in @(@{ Letter='S'; Index=0; FS='FAT32' },@{ Letter='W'; Index=2; FS='NTFS' },@{ Letter='R'; Index=3; FS='NTFS' })) {
        $part = Get-Partition -DriveLetter $check.Letter
        if ($part.DiskNumber -ne $target.Number -or $part.PartitionNumber -ne $parts[$check.Index].PartitionNumber -or
            ($part | Get-Volume).FileSystem -ne $check.FS) { throw 'Unexpected target volume.' }
    }
    Invoke-Native 'dism.exe' @('/Apply-Image',"/ImageFile:$image",('/SWMFile:' + (Join-Path $source 'Images/install*.swm')),
        '/Index:1','/ApplyDir:W:\','/CheckIntegrity','/Verify')
    $setup = 'W:\Program Files\Windows AutoSetup'
    foreach ($file in $plan.Files.PSObject.Properties | Where-Object Name -like 'AutoSetup/Seed/*') {
        $relative = $file.Name.Substring('AutoSetup/Seed/'.Length)
        $dest = if ($relative -eq 'WindowsAutoSetup.exe') { Join-Path $setup $relative }
            else { Join-Path (Join-Path $setup 'Seed') $relative }
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $dest -Parent)
        Copy-Item -LiteralPath (Join-Path $source $file.Name) -Destination $dest
        if ((Get-FileHash -LiteralPath $dest).Hash -ne $file.Value) { throw 'Staged file verification failed.' }
    }
    foreach ($file in 'Worker.ps1','PostEntry.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $setup
    }
    $null = New-Item -ItemType Directory -Force -Path 'W:\Windows\Panther','R:\Recovery\WindowsRE'
    Write-Unattend 'W:\Windows\Panther\unattend.xml' $plan
    Copy-Item -LiteralPath 'W:\Windows\System32\Recovery\Winre.wim' -Destination 'R:\Recovery\WindowsRE\Winre.wim'
    Invoke-Native 'W:\Windows\System32\reagentc.exe' @('/setreimage','/path','R:\Recovery\WindowsRE','/target','W:\Windows')
    Invoke-Native 'W:\Windows\System32\bcdboot.exe' @('W:\Windows','/s','S:','/f','UEFI')
    if (-not (Test-Path -LiteralPath 'S:\EFI\Microsoft\Boot\BCD')) { throw 'Missing target BCD.' }
    Write-Host 'Image applied. Eject the ISO and restart to complete Windows OOBE.' -ForegroundColor Green
    $null = Read-Host 'Press Enter when the ISO has been removed'
    Invoke-Native 'wpeutil.exe' @('Reboot')
} catch {
    Write-Host ('STOP: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host 'No other target will be selected. Use the retained ISO and VM backup to recover.'
    $null = Read-Host 'Press Enter to return to WinPE'
    exit 1
}
