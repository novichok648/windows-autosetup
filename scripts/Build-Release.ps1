[CmdletBinding()]
param([string]$Dotnet = 'dotnet')
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
function Invoke-Dotnet([string[]]$Arguments) {
    & $Dotnet @Arguments | Out-Host
    if ($LASTEXITCODE) { throw "dotnet exited with $LASTEXITCODE." }
}
Push-Location -LiteralPath $root
try {
    $version = (Get-Content -LiteralPath global.json -Raw | ConvertFrom-Json).sdk.version
    if ((& $Dotnet --version) -ne $version) { throw "Install .NET SDK $version." }
    $winps = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell/v1.0/powershell.exe'
    & $winps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File tests/Test-Deployment.ps1
    if ($LASTEXITCODE) { throw 'Deployment checks failed.' }
    Invoke-Dotnet @('run','--project','tests/WindowsAutoSetup.Tests','-c','Release')
    $out = Join-Path $root 'dist/portable'
    Invoke-Dotnet @('publish','src/WindowsAutoSetup','-c','Release','-r','win-x64','--self-contained','true',
        '-p:PublishSingleFile=true','-p:IncludeNativeLibrariesForSelfExtract=true','-p:DebugType=None',
        '-p:ContinuousIntegrationBuild=true','-o',$out)
    $sdk = (& $Dotnet --list-sdks | Where-Object { $_ -like "$version *" } | Select-Object -First 1)
    if ($sdk -match '\[(.+)\]$') {
        $licDir = Split-Path $Matches[1] -Parent
        foreach ($name in 'LICENSE.txt','ThirdPartyNotices.txt') {
            $path = Join-Path $licDir $name
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $out "dotnet-$name") -Force }
        }
    }
    Copy-Item -LiteralPath LICENSE -Destination (Join-Path $out 'LICENSE-WindowsAutoSetup.txt') -Force
    Copy-Item -LiteralPath README.md -Destination $out -Force
    $exe = Join-Path $out 'WindowsAutoSetup.exe'
    $smoke = Start-Process -FilePath $exe -ArgumentList '--verify-portable' -WindowStyle Hidden -Wait -PassThru
    if ($smoke.ExitCode) { throw "Portable executable verification returned $($smoke.ExitCode)." }
    Write-Host 'PASS Published portable executable and embedded inventory'
    $files = @($exe,(Join-Path $out 'README.md'),(Join-Path $out 'LICENSE-WindowsAutoSetup.txt')) +
        @(Get-ChildItem -LiteralPath $out -Filter 'dotnet-*.txt' -File | ForEach-Object FullName)
    $zip = Join-Path $root 'dist/WindowsAutoSetup-v1.0.0-preview.1-win-x64.zip'
    Compress-Archive -LiteralPath $files -DestinationPath $zip -CompressionLevel Optimal -Force
    foreach ($path in $exe,$zip) {
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        [IO.File]::WriteAllText("$path.sha256","$hash  $([IO.Path]::GetFileName($path))" + [Environment]::NewLine)
    }
    Get-FileHash -LiteralPath $exe,$zip -Algorithm SHA256
} finally { Pop-Location }
