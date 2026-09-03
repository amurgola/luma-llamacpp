# luma-llamacpp

LumaByte's patched [llama.cpp](https://github.com/ggml-org/llama.cpp) builds for
[LumaBrowser](https://lumabyte.com). This is **not a fork** — it is a small,
auditable patch stack applied on top of a pinned upstream commit, rebuilt as
upstream moves. Every patch either has an upstream PR in flight or is
LumaBrowser-specific glue.

## Why

LumaBrowser's singularity placement mode swaps the LLM and image servers on and
off one GPU per chat turn, and pins model files into locked RAM
(VirtualLock/mlock) so those swaps never touch disk. That workload cares about
one number upstream optimizes less aggressively: **cold process
load-to-healthy time**. The patches here target it.

## Patch stack

| # | Patch | Status |
|---|---|---|
| 0001 | `llama_mmap::populate()` — ranged working-set population (PrefetchVirtualMemory / madvise) | upstream candidate |
| 0002 | Async pinned-staging uploads + parallel prefault for mmap-sourced weights | upstream candidate |

Measured together on a 21.5 GiB Q6_K model (warm page cache, RTX 5090, Windows
11): `--load-mode mmap` load-to-healthy 12.8s → **8.25s**, with the
weight-upload phase alone going ~6.7s → ~2.2s (~3.2 → ~9.8 GB/s). mmap becomes
the fastest load mode while keeping its zero-copy RAM profile — which is
exactly what a RAM-pinned model wants.

## Layout

```
UPSTREAM_REF                 pinned upstream commit the stack is tested against
patches/NNNN-*.patch         git format-patch files, applied in order with git am
scripts/checkout.ps1         clone upstream @ UPSTREAM_REF into work/ and apply the stack
scripts/build-windows-cuda.ps1  build llama-server + package release zips
.github/workflows/release.yml   tag-triggered CI release build
```

## Building locally (Windows)

Prereqs: VS 2022 Build Tools (C++ workload), CUDA toolkit 12.x, cmake + ninja
on PATH. Note: nvcc 12.x cannot use the VS **2026** compiler (cudafe++
crashes) — the 2022 toolset is required.

```powershell
.\scripts\checkout.ps1                       # work/llama.cpp @ UPSTREAM_REF + patches
.\scripts\build-windows-cuda.ps1 -Tag local  # dist/llama-local-bin-win-cuda-12.8-x64.zip (+ cudart zip)
```

## Releases and LumaBrowser integration

Release assets deliberately match ggml-org's naming so LumaBrowser's runtime
installer regexes consume them unchanged:

```
llama-<tag>-bin-win-cuda-12.x-x64.zip     llama-server + ggml/llama DLLs
cudart-llama-bin-win-cuda-12.x-x64.zip    cudart/cublas runtime DLLs
```

Pointing LumaBrowser at this feed is a one-line repo swap in the runtime
catalog entry (or a data-only runtime row from an extension, the ik_llama
pattern).

## Syncing with upstream

1. Bump `UPSTREAM_REF` to the new upstream commit.
2. `.\scripts\checkout.ps1` — `git am --3way` reports any patch that no longer
   applies; fix it in `work/llama.cpp`, re-`format-patch`, replace in
   `patches/`.
3. Rebuild, run the load benchmark, tag `luma-b<upstream-build>.<n>`.

Patches that land upstream get deleted from the stack — the goal is for this
repo to trend toward empty.

## License

MIT, same as upstream llama.cpp. The patches are offered upstream under MIT.
