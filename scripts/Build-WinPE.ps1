#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WindowsIso,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$IsoSha256,
    [Parameter(Mandatory)][ValidateRange(1,100)][int]$ProIndex,
    [Parameter(Mandatory)][string]$Destination,
    [string]$Adk = (([Environment]::GetFolderPath('ProgramFilesX86')) + '\Windows Kits\10\Assessment and Deployment Kit')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Invoke-Dism([string[]]$Arguments) {
    & $dism /English @Arguments | Out-Host
    if ($LASTEXITCODE) { throw "DISM exited with $LASTEXITCODE." }
}
$iso = (Resolve-Path -LiteralPath $WindowsIso).ProviderPath
$work = [IO.Path]::GetFullPath($Destination)
if ((Test-Path -LiteralPath $work) -or $work.StartsWith('\\') -or
    [IO.DriveInfo]::new([IO.Path]::GetPathRoot($work)).DriveFormat -ne 'NTFS') {
    throw 'Choose a new directory on a local NTFS volume.'
}
if ([IO.DriveInfo]::new([IO.Path]::GetPathRoot($work)).AvailableFreeSpace -lt 20GB) {
    throw 'Allow at least 20 GiB for media servicing.'
}
if ((Get-FileHash -LiteralPath $iso -Algorithm SHA256).Hash -ne $IsoSha256) {
    throw 'ISO digest does not match the supplied Microsoft SHA-256.'
}
$pe = Join-Path $Adk 'Windows Preinstallation Environment/amd64'
$dism = Join-Path $Adk 'Deployment Tools/amd64/DISM/dism.exe'
$mount = Join-Path $work 'Mount'
$media = Join-Path $work 'Media'
$boot = Join-Path $media 'sources/boot.wim'
$wim = Join-Path $work 'install-export.wim'
$mounted = $false
$ownedIso = $false
try {
    if ((Get-DiskImage -ImagePath $iso).Attached) { throw 'Detach the source ISO before running this build.' }
    $mountedIso = Mount-DiskImage -ImagePath $iso -StorageType ISO -Access ReadOnly -PassThru
    $ownedIso = $true
    $volume = $mountedIso | Get-Volume
    if (-not $volume.DriveLetter) { throw 'The mounted ISO did not get a drive letter.' }
    $src = "$($volume.DriveLetter):\sources"
    $image = @('install.wim','install.esd') | ForEach-Object { Join-Path $src $_ } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    if (-not $image) { throw 'Install image not found.' }
    $description = (& $dism /English /Get-WimInfo "/WimFile:$image" "/Index:$ProIndex") -join [Environment]::NewLine
    if ($LASTEXITCODE -or $description -notmatch '(?m)^Edition\s*:\s*Professional\s*$' -or
        $description -notmatch '(?m)^Architecture\s*:\s*x64\s*$' -or
        $description -notmatch '(?m)^\s*ru-RU\s+\(Default\)' -or
        $description -notmatch '(?m)^Version\s*:\s*10\.0\.(2[2-9][0-9]{3}|[3-9][0-9]{4,})\s*$') {
        throw 'Choose the index for Russian Windows 11 Pro x64.'
    }
    $null = New-Item -ItemType Directory -Path $work
    $null = New-Item -ItemType Directory -Path $mount
    Copy-Item -LiteralPath (Join-Path $pe 'Media') -Destination $media -Recurse
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $boot -Parent),(Join-Path $media 'Images')
    Copy-Item -LiteralPath (Join-Path $pe 'en-us/winpe.wim') -Destination $boot
    (Get-Item -LiteralPath $boot).IsReadOnly = $false
    Invoke-Dism @('/Export-Image',"/SourceImageFile:$image","/SourceIndex:$ProIndex","/DestinationImageFile:$wim",
        '/Compress:max','/CheckIntegrity')
    $split = Join-Path $media 'Images/install.swm'
    Invoke-Dism @('/Split-Image',"/ImageFile:$wim","/SWMFile:$split",'/FileSize:3800','/CheckIntegrity')
    Invoke-Dism @('/Mount-Image',"/ImageFile:$boot",'/Index:1',"/MountDir:$mount")
    $mounted = $true
    foreach ($component in 'WMI','NetFX','Scripting','PowerShell','StorageWMI','DismCmdlets') {
        foreach ($name in "WinPE-$component.cab",('en-us/WinPE-' + $component + '_en-us.cab')) {
            $cab = Join-Path $pe "WinPE_OCs/$name"
            Invoke-Dism @("/Image:$mount",'/Add-Package',"/PackagePath:$cab")
        }
    }
    $embedded = Join-Path $mount 'AutoSetup'
    $null = New-Item -ItemType Directory -Path $embedded
    $imageHashes = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath (Join-Path $media 'Images') -Filter 'install*.swm' -File) {
        $imageHashes['Images/' + $file.Name] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    $imageHashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $embedded 'ImageManifest.json') -Encoding ASCII
    foreach ($file in 'WinPE.ps1','DiskSafety.psm1','Worker.ps1','PostEntry.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../deployment/$file") -Destination $embedded
    }
    @'
@echo off
wpeinit
if errorlevel 1 exit /b 1
%SYSTEMROOT%\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -ExecutionPolicy Bypass -File X:\AutoSetup\WinPE.ps1
'@ | Set-Content -LiteralPath (Join-Path $mount 'Windows/System32/startnet.cmd') -Encoding ASCII
    Invoke-Dism @('/Unmount-Image',"/MountDir:$mount",'/Commit')
    $mounted = $false
    $manifest = [ordered]@{}
    foreach ($file in Get-ChildItem -LiteralPath $media -Recurse -File | Sort-Object FullName) {
        if ($file.Length -ge 4GB) { throw 'A media file exceeds the FAT32 file size limit.' }
        $key = $file.FullName.Substring($media.Length + 1).Replace('\','/')
        if ($key -ieq 'sources/boot.wim') { $key = 'sources/boot.wim' }
        $manifest[$key] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    $manifest | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $media 'bundle.json') -Encoding ASCII
    Remove-Item -LiteralPath $wim
    Write-Output $media
} finally {
    if ($mounted) { & $dism /English /Unmount-Image "/MountDir:$mount" /Discard | Out-Host }
    if ($ownedIso) { Dismount-DiskImage -ImagePath $iso | Out-Null }
}
