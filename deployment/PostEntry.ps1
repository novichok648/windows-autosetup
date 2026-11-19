$ErrorActionPreference = 'Stop'
$seed = Join-Path $PSScriptRoot 'Seed'
$request = [pscustomobject]@{
    Action = 'Start'
    Source = $seed
    Mode = 'Post'
    ProfileHash = (Get-FileHash -LiteralPath (Join-Path $seed 'Config/profile.json')).Hash
    Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}
$script = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Worker.ps1'))
& ([scriptblock]::Create($script))
