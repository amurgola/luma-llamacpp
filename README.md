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
| 0003 | Overlap vocab construction with tensor loading (`n_vocab` and `n_token_types` pre-read from gguf metadata) — hides ~1.9s of 250k-vocab build behind the weight upload | upstream candidate |
| 0004 | Dual-threaded mmap staging copies | upstream candidate |
| 0005 | DeepSeek-V4.1-Flash (`deepseek41`) with unsloth's MXFP8 Engram table: ggml-org/llama.cpp#30817 verbatim (danielhanchen:deepseek41, b72050d03 on b11716) | upstream PR, open |
| 0006 | `llama_host_stager`: pinned, multi-threaded staging for every upload of a host-resident MoE expert (the MoE cache's misses and the staged prompt batches), with low memory priority for prompt scans so they stop evicting the experts generation hits (`--moe-stage-mib`, default 128) | upstream candidate |
| 0007 | `--moe-profile PATH`: expert use counts kept across runs; the next run seeds the MoE cache with the most used experts before the first token, and cache stats are logged every 4096 slot-map copies | upstream candidate |
| 0008 | `--moe-ram-mib N`: a locked RAM tier of host experts under the device cache (VirtualLock / mlock after a ranged prefetch, most used first with a profile) | upstream candidate |
| 0009 | `--moe-cache-batch N` plus the per-request `moe_cache_batch` field: the largest prompt batch served by the MoE cache is no longer a constant 32 | upstream candidate |

Landed upstream and dropped from the stack:

- Persist context checkpoints in slot save/restore (was 0003) — upstream
  ggml-org/llama.cpp#26004 stores them inside the slot file instead of a
  sidecar. Verified on b11721: a 6087-token Qwen3.8 prompt reprocesses 4 tokens
  after save → restart → restore. Old sidecar files are simply ignored.

Measured together on a 21.5 GiB Q6_K model (warm page cache, RTX 5090, Windows
11): `--load-mode mmap` load-to-healthy 12.8s → **8.25s**, with the
weight-upload phase alone going ~6.7s → ~2.2s (~3.2 → ~9.8 GB/s). mmap becomes
the fastest load mode while keeping its zero-copy RAM profile — which is
exactly what a RAM-pinned model wants.

## Expert tiers (0006 to 0009)

For a MoE model whose experts stay in host memory (`--cpu-moe` plus
`--moe-cache-mib`), upstream has two tiers that know nothing about each other:
a small LRU of experts on the GPU and the OS page cache under the mapping. Every
upload of an expert is a synchronous driver copy that soft-faults the mapping
one page at a time on one thread, and every prompt batch above 32 tokens stages
all the experts of every layer through the GPU, so on a model bigger than RAM
(DeepSeek-V4.1-Flash: 289 GB of experts on a 190 GB box) a 40-token chat turn
took about 50 s and flushed the experts generation had warmed. The four
patches turn that into tiers the app can size:

- GPU cache (upstream), seeded from the profile before the first token;
- locked RAM (`--moe-ram-mib`): the next most used experts, which neither a
  prompt scan nor another process can page out;
- page cache, then the SSD, read through pinned staging buffers by several
  threads with the reads of a whole layer in flight at once; prompt scans
  read at low memory priority so the OS evicts their pages first.

`--moe-cache-batch` and the request field `moe_cache_batch` decide which
prompts read the cache instead of scanning the pool; LumaBrowser raises it for
turns it knows start long work (its agent runs with code and artifact tools).

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

Re-measured on the b11721 rebase (same model and machine, `--load-mode mmap
--fit off`, sm_120 build, unpatched b11721 built with identical flags as the
baseline): load-to-healthy **9.3s → 4.0s**, greedy completions and BERT
embeddings byte-identical to the unpatched build.

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
