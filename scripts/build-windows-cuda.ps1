# Build llama-server (CUDA) from work/llama.cpp and package the two release
# zips LumaBrowser's runtime installer expects:
#   llama-<Tag>-bin-win-cuda-<ver>-x64.zip    server + ggml/llama DLLs
#   cudart-llama-bin-win-cuda-<ver>-x64.zip   CUDA runtime DLLs (redistributed
#                                             per the CUDA EULA redist list)
# Requires: VS 2022 Build Tools (nvcc 12.x cannot host the VS2026 compiler),
# cmake + ninja on PATH, a CUDA 12.x toolkit.
param(
  [string]$Tag = 'local',
  [string]$CudaPath = 'C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8',
  # Ampere consumer / Ada / Blackwell consumer. Add archs as needed; each one
  # costs full kernel compilation time.
  [string]$Archs = '86;89;120'
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path "$PSScriptRoot\.."
$work = Join-Path $root 'work\llama.cpp'
$dist = Join-Path $root 'dist'
if (-not (Test-Path $work)) { throw 'work/llama.cpp missing - run scripts\checkout.ps1 first.' }

# CUDA minor version rides in the asset name (the installer regex accepts any 12.x).
$cudaVer = (Split-Path $CudaPath -Leaf) -replace '^v', ''

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsroot = & $vswhere -products * -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
if (-not $vsroot) { throw 'No VS 2022 toolset with C++ tools found (vswhere).' }
$vcvars = Join-Path $vsroot 'VC\Auxiliary\Build\vcvars64.bat'

# LLAMA_OPENSSL must stay OFF: it defaults ON upstream, and GitHub's
# windows runners ship OpenSSL 3, so CI builds silently dynamic-link the
# runner's libssl/libcrypto DLLs — which aren't packaged, giving end users
# STATUS_DLL_NOT_FOUND (0xC0000135). LumaBrowser never uses the server's
# HTTPS downloader, so nothing is lost.
$nvcc = Join-Path $CudaPath 'bin\nvcc.exe'

# The server embeds upstream's prebuilt web UI, fetched by build number. The
# patched tree's number (the pin plus the patches) is not an upstream build
# unless one happens to exist, and the fallback to 'latest' is a UI the pinned
# sources can reject ("missing required asset": luma-b8, 12 patches on b11721).
# Ask for the UI of the pinned commit itself. A shallow clone miscounts and
# falls back to 'latest' as before.
if (-not $env:HF_UI_VERSION) {
  $pin = (Get-Content (Join-Path $root 'UPSTREAM_REF') | Select-Object -First 1).Trim()
  $pinBuild = git -C $work rev-list --count $pin
  if ($LASTEXITCODE -eq 0 -and $pinBuild) { $env:HF_UI_VERSION = "b$pinBuild" }
}
Write-Host "web UI assets: $env:HF_UI_VERSION"

cmd /c "call `"$vcvars`" >nul && cmake -S `"$work`" -B `"$work\build`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DGGML_NATIVE=OFF -DCMAKE_CUDA_ARCHITECTURES=`"$Archs`" -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DCMAKE_CUDA_COMPILER=`"$nvcc`" && ninja -C `"$work\build`" llama-server"
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }

New-Item -ItemType Directory -Force $dist | Out-Null
$binZip = Join-Path $dist "llama-$Tag-bin-win-cuda-$cudaVer-x64.zip"
$cudartZip = Join-Path $dist "cudart-llama-bin-win-cuda-$cudaVer-x64.zip"
if (Test-Path $binZip) { Remove-Item $binZip -Confirm:$false }
if (Test-Path $cudartZip) { Remove-Item $cudartZip -Confirm:$false }

Compress-Archive -Path "$work\build\bin\*.exe", "$work\build\bin\*.dll" -DestinationPath $binZip
$cudaMajor = $cudaVer.Split('.')[0]
$runtimeDlls = Get-ChildItem "$CudaPath\bin" | Where-Object {
  $_.Name -match "^(cudart64|cublas64|cublasLt64)_$cudaMajor.*\.dll$"
}
if (-not $runtimeDlls) { throw "no CUDA runtime DLLs found under $CudaPath\bin" }
Compress-Archive -Path $runtimeDlls.FullName -DestinationPath $cudartZip

Get-Item $binZip, $cudartZip | Select-Object Name, @{n='MB';e={[math]::Round($_.Length/1MB,1)}}
