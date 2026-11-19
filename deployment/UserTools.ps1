$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { exit 6 }
$allow = '@openai/codex','paperclipai','playwright'
if ($selected.Count -lt 1 -or $selected.Count -gt 3 -or @($selected | Where-Object { $_ -notin $allow }).Count) { exit 2 }
$base = Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'nodejs'
$node = Join-Path $base 'node.exe'
$npm = Join-Path $base 'node_modules/npm/bin/npm-cli.js'
if (-not (Test-Path -LiteralPath $npm) -or (Get-AuthenticodeSignature -LiteralPath $node).Status -ne 'Valid') { exit 2 }
$prefix = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WindowsAutoSetup/DevTools'
$null = New-Item -ItemType Directory -Path $prefix -Force
Push-Location -LiteralPath $prefix
try {
    foreach ($id in $selected) {
        & $node $npm list $id '--depth=0' *> $null
        if ($LASTEXITCODE) {
            & $node $npm install $id '--save-exact' '--registry=https://registry.npmjs.org' '--no-fund' '--no-audit' *> $null
            if ($LASTEXITCODE) { exit 2 }
            & $node $npm list $id '--depth=0' *> $null
            if ($LASTEXITCODE) { exit 2 }
        }
        if ($id -eq 'playwright') {
            & $node (Join-Path $prefix 'node_modules/playwright/cli.js') install chromium *> $null
            if ($LASTEXITCODE) { exit 2 }
        }
    }
} finally { Pop-Location }
exit 0
