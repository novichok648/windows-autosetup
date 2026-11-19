#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$OfficialIso,
    [Parameter(Mandatory)][string]$LabDirectory
)
$ErrorActionPreference = 'Stop'
$image = (Resolve-Path -LiteralPath $OfficialIso).ProviderPath
if ([IO.Path]::GetExtension($image) -ne '.iso') { throw 'Select an installation ISO.' }
$name = 'WindowsAutoSetup-Lab-' + [guid]::NewGuid().ToString('N').Substring(0,12)
$root = Join-Path ([IO.Path]::GetFullPath($LabDirectory)) $name
if ((Test-Path -LiteralPath $root) -or (Get-VM -Name $name -ErrorAction SilentlyContinue)) { throw 'Lab name collision.' }
$null = New-Item -ItemType Directory -Path $root
$vhd = Join-Path $root 'System.vhdx'
$vm = New-VM -Name $name -Generation 2 -Path $root -NewVHDPath $vhd -NewVHDSizeBytes 96GB -MemoryStartupBytes 8GB
Set-VMProcessor -VM $vm -Count 4 -ExposeVirtualizationExtensions $true
Set-VMKeyProtector -VMName $name -NewLocalKeyProtector
Enable-VMTPM -VMName $name
Add-VMDvdDrive -VMName $name -Path $image
$dvd = Get-VMDvdDrive -VMName $name | Select-Object -First 1
Set-VMFirmware -VMName $name -EnableSecureBoot On -SecureBootTemplate MicrosoftWindows -FirstBootDevice $dvd
Start-VM -VM $vm
Get-VM -Name $name | Select-Object Name,State,Id
