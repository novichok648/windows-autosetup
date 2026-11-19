Set-StrictMode -Version Latest

function Normalize-DiskValue($Value) {
    return ([string]$Value).Trim().ToUpperInvariant()
}

function Get-DiskIdentity($Disk) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$Disk.Guid, [ref]$guid) -or $guid -eq [guid]::Empty) {
        $guid = [guid]::Empty
    }
    $partitions = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop |
        Sort-Object Offset | ForEach-Object { '{0}:{1}:{2}' -f $_.Offset, $_.Size, (Normalize-DiskValue $_.GptType) })
    [pscustomobject]@{
        Number = [int]$Disk.Number
        Guid = $guid.ToString()
        Serial = Normalize-DiskValue $Disk.SerialNumber
        Model = Normalize-DiskValue $Disk.FriendlyName
        Size = [uint64]$Disk.Size
        Bus = Normalize-DiskValue $Disk.BusType
        UniqueId = Normalize-DiskValue $Disk.UniqueId
        Style = [string]$Disk.PartitionStyle
        Layout = $partitions -join ';'
    }
}

function Resolve-TargetDisk($Expected, [object[]]$Disks) {
    $guid = [guid]::Empty
    if (-not [guid]::TryParse([string]$Expected.Guid, [ref]$guid) -or $guid -eq [guid]::Empty -or
        $Expected.Serial -notmatch '[A-Z0-9]{3,}' -or $Expected.Serial -match '^(0+|UNKNOWN|NONE|DEFAULT)$' -or
        -not $Expected.UniqueId -or -not $Expected.Model -or -not $Expected.Layout -or
        $Expected.Style -ne 'GPT' -or $Expected.Bus -match 'USB|SD|MMC|UNKNOWN' -or
        [uint64]$Expected.Size -lt 64GB) { throw 'Incomplete or unsupported target identity.' }
    $related = @($Disks | Where-Object {
        $_.Guid -eq $Expected.Guid -or $_.Serial -eq $Expected.Serial -or $_.UniqueId -eq $Expected.UniqueId
    })
    if ($related.Count -ne 1) { throw 'Missing or ambiguous disk identity.' }
    $actual = $related[0]
    foreach ($property in 'Guid','Serial','Model','Size','Bus','UniqueId','Style','Layout') {
        if ($actual.$property -ne $Expected.$property) { throw "Target disk mismatch ($property)." }
    }
    return $actual
}

function Get-LiveDiskIdentities {
    foreach ($disk in Get-Disk -ErrorAction Stop) {
        if ($disk.PartitionStyle -eq 'GPT') {
            Get-DiskIdentity $disk
        } else {
            [pscustomobject]@{
                Number = [int]$disk.Number; Guid = ''; Serial = Normalize-DiskValue $disk.SerialNumber
                UniqueId = Normalize-DiskValue $disk.UniqueId; Model = ''; Size = [uint64]$disk.Size
                Bus = Normalize-DiskValue $disk.BusType; Style = [string]$disk.PartitionStyle; Layout = ''
            }
        }
    }
}

function Assert-LabGuest {
    $pc = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
    if ($pc.Manufacturer -ne 'Microsoft Corporation' -or $pc.Model -ne 'Virtual Machine') {
        throw 'This preview permits disk deployment only inside an isolated Hyper-V guest.'
    }
}

function Assert-LabDisk($Disk) {
    if ($Disk.Model -ne 'MICROSOFT VIRTUAL DISK' -or $Disk.Bus -ne 'SCSI') {
        throw 'Only Hyper-V SCSI virtual disks are supported by this preview.'
    }
}

Export-ModuleMember -Function Get-DiskIdentity,Resolve-TargetDisk,Get-LiveDiskIdentities,Assert-LabGuest,Assert-LabDisk
