[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Bundle,
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{20}$')][string]$ApprovalCode,
    [string]$Adk = (([Environment]::GetFolderPath('ProgramFilesX86')) + '\Windows Kits\10\Assessment and Deployment Kit')
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath $Bundle).ProviderPath.TrimEnd('\')
$dest = [IO.Path]::GetFullPath($Destination)
if ((Test-Path -LiteralPath $dest) -or [IO.Path]::GetExtension($dest) -ne '.iso') { throw 'Supply the path of a new ISO file.' }
$planPath = Join-Path $root 'deployment-plan.json'
$digest = (Get-FileHash -LiteralPath $planPath).Hash
if ($digest.Substring(0,20) -ne $ApprovalCode) { throw 'Incorrect approval code.' }
$plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
$manifest = Get-Content -LiteralPath (Join-Path $root 'bundle.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($plan.BootSha256 -notmatch '^[a-fA-F0-9]{64}$' -or $manifest.'sources/boot.wim' -ne $plan.BootSha256) {
    throw 'The Windows PE boot image is not the one approved in the plan.'
}
$all = [ordered]@{}
foreach ($file in @($manifest.PSObject.Properties) + @($plan.Files.PSObject.Properties)) {
    if ($all.Contains($file.Name) -and $all[$file.Name] -ne $file.Value) { throw 'Manifest conflict.' }
    $all[$file.Name] = $file.Value
}
$all['deployment-plan.json'] = $digest
$temp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath.TrimEnd('\')
$scratch = Join-Path $temp ('AutoSetupIso-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
try {
    foreach ($pair in $all.GetEnumerator()) {
        $key = $pair.Key
        if ($key -notmatch '^(EFI/|Boot/|sources/boot\.wim$|Images/install\d*\.swm$|AutoSetup/Seed/|bootmgr(\.efi)?$|boot\.sdi$|deployment-plan\.json$)' -or
            $key -match '[\\:*?"<>|]' -or ($key -split '/') -match '(\.$|^$|[ ]$|[\x00-\x1F])') {
            throw 'Unexpected file in an ISO manifest.'
        }
        $from = Join-Path $root $key
        $to = Join-Path $scratch $key
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $to -Parent)
        Copy-Item -LiteralPath $from -Destination $to
        if ((Get-FileHash -LiteralPath $to).Hash -ne $pair.Value) { throw 'ISO file checksum failed.' }
    }
    $boot = Join-Path $scratch 'EFI/Microsoft/Boot/efisys_noprompt.bin'
    if (-not (Test-Path -LiteralPath $boot)) { $boot = Join-Path $scratch 'EFI/Microsoft/Boot/efisys.bin' }
    if (-not (Test-Path -LiteralPath $boot)) { $boot = Join-Path $Adk 'Deployment Tools/amd64/Oscdimg/efisys.bin' }
    $oscdimg = Join-Path $Adk 'Deployment Tools/amd64/Oscdimg/oscdimg.exe'
    & $oscdimg '-m' '-o' '-u2' '-udfver102' "-bootdata:1#pEF,e,b$boot" $scratch $dest
    if ($LASTEXITCODE) { throw "Oscdimg exited with $LASTEXITCODE." }
} finally {
    $resolved = (Resolve-Path -LiteralPath $scratch).ProviderPath
    if ($resolved -eq $scratch -and (Split-Path $resolved -Parent) -eq $temp -and
        (Split-Path $resolved -Leaf) -match '^AutoSetupIso-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
Get-FileHash -LiteralPath $dest
