$ErrorActionPreference = 'Stop'
$board = Get-CimInstance Win32_BaseBoard | Select-Object -First 1
$pc = Get-CimInstance Win32_ComputerSystem
$gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object {
    [pscustomobject]@{ Name = $_.Name; Version = $_.DriverVersion; Hz = $_.CurrentRefreshRate }
})
$target = $null
$storageError = $false
try {
    $osPart = Get-Partition -DriveLetter $env:SystemDrive.Substring(0,1) -ErrorAction Stop
    $disk = Get-Disk -Number $osPart.DiskNumber -ErrorAction Stop
    $target = Get-DiskIdentity $disk
    if (-not $disk.IsBoot -or -not $disk.IsSystem) { $storageError = $true }
} catch { $storageError = $true }
$firmware = 'Unknown'
try { $firmware = (Get-ComputerInfo -Property BiosFirmwareType).BiosFirmwareType.ToString() } catch {}
$zone = (Get-TimeZone).Id
[pscustomobject]@{
    Board = "$($board.Manufacturer) $($board.Product)"
    Model = $pc.Model
    Lab = ($pc.Manufacturer -eq 'Microsoft Corporation' -and $pc.Model -eq 'Virtual Machine')
    Target = $target
    StorageError = $storageError
    TimeZone = $zone
    Firmware = $firmware
    GPU = $gpu
    Usb = @(
        try {
            Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem } |
                Get-Partition | Where-Object DriveLetter | ForEach-Object {
                    $volume = $_ | Get-Volume
                    if ($volume.FileSystem -eq 'FAT32') {
                        [pscustomobject]@{ Letter = [string]$_.DriveLetter; Free = $volume.SizeRemaining; VolumeId = $volume.Path }
                    }
                }
        } catch {}
    )
} | ConvertTo-Json -Depth 8 -Compress
