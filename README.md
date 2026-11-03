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
| 0010 | `--moe-ram-register-mib N`: the RAM tier is registered with the GPU (most used experts first, default 40% of RAM), so cache misses that live there upload by DMA straight from the mapping at the link's speed instead of through the staging copy | upstream candidate |

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

## Expert tiers (0006 to 0010)

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
  prompt scan nor another process can page out; its most used part is also
  registered with the GPU (`--moe-ram-register-mib`, 0010), so a miss that
  lives there is one DMA at the link's speed (47 GB/s measured on PCIe 5.0 x16)
  rather than a copy through pinned staging (16 GB/s, bounded by the memcpy);
- page cache, then the SSD, read through pinned staging buffers by several
  threads with the reads of a whole layer in flight at once; prompt scans
  read at low memory priority so the OS evicts their pages first.

`--moe-cache-batch` and the request field `moe_cache_batch` decide which
prompts read the cache instead of scanning the pool; LumaBrowser raises it for
turns it knows start long work (its agent runs with code and artifact tools).

Measured 2026-11-03 on DeepSeek-V4.1-Flash-1017 UD-Q4_K_XL (500 GB, 289 GB of
experts) on an RTX 5090 with 190 GB of RAM, b11721 plus this stack, chat mode,
32k context, a 10.6 GB MoE cache (LumaBrowser's own plan; the base row is the
same binary with `--moe-stage-mib 0`, which is upstream's upload path):

| variant | decode tok/s | 4k prompt | 40-token chat prompt | decode at 4k depth |
|---|---|---|---|---|
| base (upstream path) | 1.6 to 2.3 | 263 s | 53 to 87 s | 0.77 |
| 0006 stager | 2.5 to 2.8 | 68 s | 16 to 21 s | 1.92 |
| 0006 + 0008 RAM tier (96 GB locked) | 2.9 to 3.3 | 50 s | 16 to 23 s | 2.02 |
| above + 0007 profile seeded (2nd run) | 3.3 to 3.4 | 39 s | 11 to 17 s | 2.71 |
| above + 0009 `--moe-cache-batch 128` (3rd run) | 3.3 to 3.6 | 36 s | 6 to 15 s | 2.46 |
| above, rerun on the 0010 build with registration off | 3.3 to 3.4 | 30 s | 11 to 21 s | 2.56 |
| above + 0010 registered tier (76 GB of the 96 GB) | 5.3 to 6.0 | 32 s | 7 to 21 s | 3.83 |

The 0010 budget matters: on Windows the display driver maps host registrations
into the GPU's shared system memory, and past about half of physical RAM it
backs each further GiB with device memory until the card is full (measured:
free up to 100 GiB on a 190 GB box, then 20 GB of VRAM gone by 120 GiB). The
default registers 40% of RAM, most used experts first; the rest of the tier
stays locked and uploads through the stager.

An experiment on the same model (ten coding prompts and ten page-extraction
prompts, each run on a fresh profile, then the extraction prompts with the
cache seeded from the code profile, from a mixed profile and from their own)
found that seeding the GPU cache makes no measurable difference: every run
settled at a 42 to 45% decode hit rate from its first hundred tokens, because
a prompt of a few hundred tokens through the cache path routes to most experts
of every layer and flushes the 600-slot cache many times over before the first
generated token. The LRU alone reaches that rate. The profiles themselves do
differ (the two domains share 31% of their top 600 experts, and each covers
87% of its own routings at the RAM tier against 60% for the other), and that
ordering of the RAM tier is where the profile earns its decode gain.

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
