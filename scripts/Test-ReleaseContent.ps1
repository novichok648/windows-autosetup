$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
Push-Location -LiteralPath $root
try {
    $paths = @(git -c core.quotepath=false ls-files)
    if ($LASTEXITCODE -or $paths.Count -lt 5) { throw 'Stage project sources before checking.' }
    $checks = @(
        ('-----BEGIN ' + '(RSA |OPENSSH |EC |DSA |ENCRYPTED )?PRIVATE KEY'),
        ('gh[pousr]_' + '[A-Za-z0-9]{30,}'),
        ('github_pat_' + '[A-Za-z0-9_]{25,}'),
        ('sk-(proj-|svcacct-)?' + '[A-Za-z0-9_-]{30,}'),
        ('vless:' + '//[0-9a-fA-F-]{36}@'),
        ('(AKIA|ASIA)' + '[A-Z0-9]{16}'),
        ('xox[baprs]-' + '[A-Za-z0-9-]{15,}')
    )
    foreach ($path in $paths) {
        if ($path -match '(^|/)(Private|Logs|AutoSetup|dist|bin|obj)(/|$)|\.(exe|dll|pfx|pem|key|vault|log|zip|iso|wim|esd|swm|vhdx?)$|(^|/)\.env' -or
            $path -notmatch '^[-A-Za-z0-9._/]+$') { throw "Review unexpected staged file: $path" }
        $content = (git show ":$path") -join [Environment]::NewLine
        if ($LASTEXITCODE) { throw "Could not read staged file: $path" }
        if ($content.Length -gt 500000) { throw "Review large file: $path" }
        foreach ($pattern in $checks) {
            if ($content -cmatch $pattern) { throw "Potential credential in staged file: $path" }
        }
    }
    Write-Output "Passed staged-content check ($($paths.Count) paths)."
} finally { Pop-Location }
