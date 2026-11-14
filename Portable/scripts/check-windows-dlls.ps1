# Checks that every DLL First Row loads is either in its folder or part of Windows itself,
# so the folder runs on a PC without Swift or Visual Studio. Needs dumpbin (a Developer PowerShell).
param([string] $App = "$PSScriptRoot\..\..\dist\windows\FirstRow")
$ErrorActionPreference = "Stop"
$shipped = Get-ChildItem $App -File | ForEach-Object { $_.Name.ToLower() }
$system = Join-Path $env:SystemRoot "System32"
$missing = @{}
foreach ($file in Get-ChildItem "$App\*" -Include *.exe, *.dll) {
    $imports = & dumpbin.exe /dependents $file.FullName | Select-String "^\s{4}(\S+\.dll)\s*$" | ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() }
    foreach ($name in $imports) {
        if ($shipped -contains $name -or $name -like "api-ms-*" -or $name -like "ext-ms-*") { continue }
        # Visual Studio puts its C++ runtime in System32, but a fresh Windows may not have it.
        $vcRuntime = $name -match "^(vcruntime|msvcp|concrt|vccorlib)"
        if (-not $vcRuntime -and (Test-Path (Join-Path $system $name))) { continue }
        $missing[$name] = $file.Name
    }
}
if ($missing.Count) {
    $missing.GetEnumerator() | ForEach-Object { Write-Host "$($_.Key) (needed by $($_.Value))" }
    throw "First Row's folder is missing DLLs"
}
Write-Host "Every DLL First Row needs is in its folder or part of Windows."
