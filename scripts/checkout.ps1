# Clone upstream llama.cpp at the pinned UPSTREAM_REF into work/ and apply the
# patch stack with git am. Idempotent: re-running resets work/ to a clean
# patched state. On a ref bump, a patch that no longer applies stops here with
# git am's 3-way conflict markers to resolve.
param(
  [string]$Ref = (Get-Content "$PSScriptRoot\..\UPSTREAM_REF" | Select-Object -First 1).Trim(),
  [string]$Upstream = 'https://github.com/ggml-org/llama.cpp'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\.."
$work = Join-Path $root 'work\llama.cpp'

if (-not (Test-Path (Join-Path $work '.git'))) {
  New-Item -ItemType Directory -Force (Split-Path $work) | Out-Null
  git clone $Upstream $work
}
Push-Location $work
try {
  git am --abort 2>$null
  git fetch origin
  git checkout --detach $Ref
  git clean -fd
  Write-Host "== upstream @ $(git rev-parse --short HEAD), applying patch stack =="
  $patches = Get-ChildItem (Join-Path $root 'patches') -Filter '*.patch' | Sort-Object Name
  git am --3way $patches.FullName
  git log --oneline "-$($patches.Count + 1)"
} finally {
  Pop-Location
}
