$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$parsed = @{}
foreach ($file in Get-ChildItem -Path (Join-Path $root 'deployment'),(Join-Path $root 'scripts'),(Join-Path $root 'tests') -Recurse -Include *.ps1,*.psm1) {
    $tokens = $null
    $problems = $null
    $parsed[$file.Name] = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName,[ref]$tokens,[ref]$problems)
    if ($problems) { throw ($problems.Message -join [Environment]::NewLine) }
}
Write-Host 'PASS Windows PowerShell syntax'
Import-Module (Join-Path $root 'deployment/DiskSafety.psm1') -Force
foreach ($function in $parsed['Worker.ps1'].FindAll({ param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
}, $false)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
. ([scriptblock]::Create($parsed['WinPE.ps1'].Find({
    param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-Unattend'
}, $false).Extent.Text))
function Require([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL $Name" }
    Write-Host "PASS $Name"
}
function Reject([scriptblock]$Operation, [string]$Name) {
    try { & $Operation | Out-Null } catch { Write-Host "PASS $Name"; return }
    throw "FAIL $Name"
}
function Copy-Object($Value) { $Value | ConvertTo-Json -Depth 10 | ConvertFrom-Json }
$target = [pscustomobject]@{
    Number=0; Guid='ba60f317-447e-4ed8-b725-277620b0669e'; Serial='VHD-000123'; Model='MICROSOFT VIRTUAL DISK'
    Size=96GB; Bus='SCSI'; UniqueId='vd-fixture-0123'; Style='GPT'; Layout='1048576:272629760:ESP'
}
$renumbered = Copy-Object $target
$renumbered.Number = 4
Require ((Resolve-TargetDisk $target @($renumbered)).Number -eq 4) 'Renumbered disk accepted by full identity'
Reject { Resolve-TargetDisk $target @() } 'Missing target refused'
$duplicate = Copy-Object $target
$duplicate.Number = 2
$duplicate.Guid = [guid]::NewGuid().ToString()
Reject { Resolve-TargetDisk $target @($renumbered,$duplicate) } 'Duplicate serial refused'
$duplicate.Serial = 'VHD-456789'
Reject { Resolve-TargetDisk $target @($renumbered,$duplicate) } 'Duplicate device identity refused'
foreach ($field in 'Guid','Model','Serial','UniqueId','Size','Bus','Style','Layout') {
    $bad = Copy-Object $target
    $bad.$field = if ($field -eq 'Size') { 12GB } else { 'SUBSTITUTED' }
    Reject { Resolve-TargetDisk $target @($bad) } "Changed $field refused"
}
Reject { Assert-LabDisk ([pscustomobject]@{ Model='NVME SSD'; Bus='NVME' }) } 'Physical model refused'

$stage = [pscustomobject]@{ Status='WaitingForReboot'; Boot='boot-1'; Attempts=1; Reboots=1 }
Require ((Get-StageDecision $stage 'boot-1' 'Resume') -eq 'Hold') 'No resume before required reboot'
Require ((Get-StageDecision $stage 'boot-2' 'Resume') -eq 'Run') 'Resume same stage after reboot'
$stage.Status = 'Running'
Require ((Get-StageDecision $stage 'boot-2' 'Resume') -eq 'Interrupted') 'Unplanned interruption detected'
$stage.Status = 'Blocked'
Require ((Get-StageDecision $stage 'boot-2' 'Resume') -eq 'Hold') 'Blocked stage prevents future stages'
Require ((Get-StageDecision $stage 'boot-2' 'Retry') -eq 'Run') 'Explicit retry allowed'
$stage.Reboots = 8
Require ((Get-StageDecision $stage 'boot-2' 'Retry') -eq 'Limit') 'Reboot limit enforced'
$stage.Status = 'Completed'
Require ((Get-StageDecision $stage 'boot-2' 'Resume') -eq 'Next') 'Completed stages skipped'
Require (((Get-TaskNames Post) -join ',') -eq 'Settings,Drivers,WindowsUpdate,Apps,Faceit,Startup,FinalVerification,AccountWizard') 'Windows Update precedes Apps and FACEIT'
Require (((Get-TaskNames Dev) -join ',') -eq 'DevTools,DevPackages') 'Development run uses independent stages'

$temp = (Resolve-Path -LiteralPath ([IO.Path]::GetTempPath())).ProviderPath.TrimEnd('\')
$work = Join-Path $temp ('AutoSetupTests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$plain = [Text.UTF8Encoding]::new($false)
try {
    $path = Join-Path $work 'state.json'
    Write-Json $path @{ State = 'Pending' }
    Write-Json $path @{ State = 'Completed' }
    Require ((Get-Content -LiteralPath $path -Raw | ConvertFrom-Json).State -eq 'Completed') 'Atomic state replacement'
    $hash = (Get-FileHash -LiteralPath $path).Hash
    Assert-Hash $path $hash
    Add-Content -LiteralPath $path -Value 'tamper'
    Reject { Assert-Hash $path $hash } 'Corrupted installer digest refused'
    Reject { Copy-PinnedFile $work (Join-Path $work 'out') '../outside.exe' $hash } 'Pinned package traversal refused'
    $answer = Join-Path $work 'unattend.xml'
    Write-Unattend $answer @{ User='a'; TimeZone='Russian Standard Time' }
    [xml]$xml = Get-Content -LiteralPath $answer -Raw
    Require ($xml.unattend.settings[1].component[1].UserAccounts.LocalAccounts.LocalAccount.Name -eq 'a') 'Local account in valid answer XML'
    Require ($xml.unattend.settings[1].component[0].InputLocale -eq '0409:00000409;0419:00000419') 'Answer XML uses both requested layouts'
} finally {
    $resolved = (Resolve-Path -LiteralPath $work).ProviderPath
    if ((Split-Path $resolved -Parent) -eq $temp -and (Split-Path $resolved -Leaf) -match '^AutoSetupTests-[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}

function Test-PendingReboot { return $script:mockReboot }
function New-Object([string]$ComObject) {
    if ($ComObject -eq 'Microsoft.Update.Session') {
        $session = [pscustomobject]@{ ClientApplicationID='' }
        $session | Add-Member ScriptMethod CreateUpdateSearcher {
            $searcher = [pscustomobject]@{ Online=$false }
            $searcher | Add-Member ScriptMethod Search {
                param($criteria)
                if ($criteria -ne 'IsInstalled=0 and IsHidden=0 and BrowseOnly=0') { throw 'Search scope mismatch.' }
                if ($script:mockNetworkDown) { throw 'Simulated network loss.' }
                [pscustomobject]@{ ResultCode=$script:mockResult; Updates=@() }
            }
            $searcher
        }
        return $session
    }
    if ($ComObject -eq 'Microsoft.Update.UpdateColl') { return [pscustomobject]@{ Count=0 } }
    throw 'Unexpected COM class.'
}
$script:mockReboot = $true
$script:mockNetworkDown = $false
$script:mockResult = 2
$diagnostic = @{ Code = '' }
Require ((Invoke-WindowsUpdate) -eq 'Reboot') 'Windows Update waits on pending reboot'
$script:mockReboot = $false
Require ((Invoke-WindowsUpdate) -eq 'Done') 'Successful empty standard update search'
$script:mockResult = 3
Reject { Invoke-WindowsUpdate } 'Incomplete Windows Update search fails closed'
$script:mockNetworkDown = $true
Reject { Invoke-WindowsUpdate } 'Windows Update network failure blocks completion'
