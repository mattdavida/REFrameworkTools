# Copy the built ref_live plugin into this package.
# Source of truth for C++: REFramework/examples/ref_live/plugin.cpp

param(
    [string]$From
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $here "reframework\plugins\ref_live.dll"

$candidates = @()
if ($From) {
    $candidates += $From
}

$refRoot = Join-Path (Split-Path -Parent $here) "REFramework"
$candidates += @(
    (Join-Path $refRoot "build64_all\bin\ref_live\ref_live.dll"),
    (Join-Path $refRoot "build64_all\bin\REFramework\ref_live.dll")
)

$src = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $src) {
    throw "ref_live.dll not found. Build the ref_live target in REFramework, or pass -From <path>."
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
Copy-Item -Force $src $dest
Get-Item $dest | Format-List FullName, Length, LastWriteTime
