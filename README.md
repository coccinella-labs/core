<p align="center">
  <img src="https://raw.githubusercontent.com/coccinella-labs/core/main/.github/assets/thumbnail.png" alt="core" width="100%">
</p>

# Core

A Metal compute runtime for Apple Silicon, built to measure rather than to look fast.

Nine benchmarks cover memory bandwidth, kernel launch latency, prefix scan, matrix
multiplication, host/device transfer, and reduction. Every benchmark checks its own
correctness at small sizes and reports percentiles instead of single best-case
timings, because GPU numbers that do not include variance are not reproducible.

This is a measurement tool. It does not provide a general compute API, and it is not a
framework. If you want to write Metal shaders against an abstraction, use something
else. If you want to know what a given Apple GPU actually does at a given bandwidth or
latency, this is the tool.

Status: v0.1.0. Nine commands, correctness-checked. All numbers below were measured
on the hardware named in the results section.

## Quickstart

Requires macOS 13+, Apple Silicon, and Swift 6.1 (Xcode 16 or later).

```bash
git clone https://github.com/coccinella-labs/core
cd core
swift build -c release
```

Verify the GPU works before trusting any timing:

```console
$ ./.build/release/gpucomm selftest
selftest reduction: ok
selftest scan: ok
selftest matmul: ok
selftest overall: ok
```

`selftest` covers reduction, scan, and matmul. It does not cover transfer, which only
round-trips data rather than checking it against a reference.

Then measure something:

```bash
# bandwidth at a few sizes, percentiles over 5 repetitions, JSONL for logging
./.build/release/gpucomm bench bandwidth-sweep \
  --sizes-mib 1,4,16,64 --iters 200 --mode private --reps 5 --format jsonl

# kernel launch overhead
./.build/release/gpucomm bench latency --kind kernel --iters 2000 --warmup 200 --reps 5
```

`./.build/release/gpucomm --help` lists every command with its flags.

## Commands

| Command | Measures |
|---|---|
| `bench bandwidth` | copy throughput at one size |
| `bench bandwidth-sweep` | copy throughput across sizes |
| `bench latency` | kernel launch overhead (`--kind empty\|kernel`) |
| `bench scan` | exclusive prefix sum |
| `bench scan-sweep` | scan across sizes |
| `bench matmul` | matrix multiply (`--variant naive\|tiled8\|tiled16\|tiled32`) |
| `bench matmul-sweep` | matmul across tile and problem sizes |
| `bench transfer` | host/device transfer (`--direction`, `--strategy memcpy\|blit`) |
| `bench transfer-sweep` | transfer across sizes |
| `run reduction` | single reduction, prints the sum against its expected value |
| `selftest` | correctness for reduction, scan, matmul |

Formats are `human`, `json`, `jsonl`, and `csv`. Sweeps emit `jsonl` or `csv` only,
since they produce one record per size. Unknown commands exit non-zero.

## Measured results

MacBook Air, Apple M1 (8-core GPU), 8 GB, macOS 27.0.1, Swift 6.1 release build.
Absolute numbers are hardware-dependent; the shapes of these curves are the point.

**Copy bandwidth**, higher is better. Note that on unified memory, `shared` storage mode
is *faster* than `private`, which is the opposite of the discrete-GPU intuition:

`bench bandwidth-sweep --iters 200 --reps 5`, p50:

| Size | `private` | `shared` |
|---|---|---|
| 1 MiB | 133.7 GiB/s | 450.3 GiB/s |
| 4 MiB | 226.9 GiB/s | 463.4 GiB/s |
| 16 MiB | 372.6 GiB/s | 466.8 GiB/s |
| 64 MiB | 411.3 GiB/s | 458.4 GiB/s |
| 256 MiB | 409.6 GiB/s | 457.8 GiB/s |

Throughput climbs with size as cache effects wash out, then plateaus. On unified
memory `shared` is three to four times faster than `private` at every size, which is
the opposite of the discrete-GPU intuition you may bring to this.

**Kernel launch latency**, 2000 iterations, 200 warmup, 5 repetitions:

```
kind=kernel   GPU p50 10.0 us    p95 12.5 us
kind=empty    wall p50 17.7 us   (no GPU timestamp: the encoder is empty)
```

**Matmul at 512x512x512**, 20 iterations, 5 warmup. Tiling helps, but by 1.6x, not by
orders of magnitude, and the best tile size is narrow:

| Variant | Time | Throughput |
|---|---|---|
| `naive` | 1885 us | 143.4 GFLOP/s |
| `tiled8` | 1129 us | 240.5 GFLOP/s |
| `tiled16` | 1270 us | 213.8 GFLOP/s |
| `tiled32` | 1416 us | 191.3 GFLOP/s |

Run to run this varies by 5 to 10 percent, and `matmul` has no `--reps`, so treat
differences under about 15 percent as noise.

**Scan** at n=1048576 ranged from 0.8 ms to 34 ms of GPU time across runs on an
otherwise idle machine. That spread is the honest result and the reason the tool
reports percentiles. Note also that `bench scan` silently clamps `n` to 1048576, so a
larger request measures the clamp rather than what you asked for.

To reproduce any of these, run the same command on your machine and report the chip,
macOS version, Swift version, and commit SHA. Do not compare across chips without saying
so.

## Reading results honestly

GPU timings move for reasons that have nothing to do with your code: thermal state,
battery mode, other GPU work, and background processes. This is not a bug in the
benchmark, it is why the tool takes warmup and repetition counts.

Practical rules:

- Flags must be passed in the order the parser reads them. `ArgReader` in
  `Sources/gpucomm/Args.swift` walks the argument list once, so `--mode` before
  `--reps` works and the reverse does not, even though `--help` lists them
  alphabetically and nothing says order matters. Match the order in `--help`, or the
  examples above.
- Plug in and disable low-power mode for anything you intend to publish.
- Always pass `--reps` above 1 and report p50 and p95, never a single peak.
- Record the commit SHA. A number without one cannot be reproduced.
- GPU-side numbers come from Metal timestamp queries and have microsecond granularity.
  Anything below roughly 10 us is close to the noise floor; use `--kind empty` to measure
  the submission overhead you are subtracting.
- `scan` is capped at n=1048576 and clamps silently.
- Transfer checks that data round-trips, not that it matches a reference implementation.
  A wrong-but-consistent copy would pass.

CI builds and runs `selftest` on a shared runner, but measures no performance. GitHub
Actions runners have no dedicated GPU and their numbers are meaningless. Every
performance figure in this README was produced locally.

## Architecture

Four layers, from the bottom up:

- `Sources/GPUCommCore/MetalContext.swift` owns the device and command queue.
- `Sources/GPUCommCore/KernelLibrary.swift` compiles `Kernels.metal` as text at startup.
  `Package.swift` uses `.copy` rather than `.process` for this resource, because
  `.process` compiles it into `default.metallib`, drops the source, and the binary then
  fails at startup. CI asserts the bundle contains the source file.
- `Sources/GPUCommCore/Benchmarks/` holds one file per experiment.
- `Sources/gpucomm/main.swift` parses and dispatches, `Sources/gpucomm/Output.swift`
  formats, `Sources/gpucomm/Stats.swift` computes percentiles, and
  `Sources/gpucomm/Args.swift` holds the flag parsing.

There are no external dependencies. Swift, Metal, and Foundation only.

## Development

```bash
swift build -c release
swift test        # README drift guard, no GPU required
pre-commit run --all-files
```

`Tests/GPUCommCoreTests/ReadmeDriftTests.swift` asserts that this file stays in step with
the code: every CLI command is documented, referenced source paths exist, and the
known-false claims that previously shipped here cannot come back. It runs under
`swift test`, so documentation drift fails the build. The tests read files as text and
never create a Metal device, so they pass on GPU-less CI runners.

## Contributing

Branch, change, `swift test`, open a PR. New benchmarks go in
`Sources/GPUCommCore/Benchmarks/` as one file, need a dispatcher case in
`main.swift`, and need at least one small-size correctness check. If you add a Metal
kernel, put it in `Sources/GPUCommCore/Resources/Kernels/Kernels.metal` and test it on
real hardware before claiming any result, because CI cannot do that for you.

`AGENTS.md` covers how GPU patterns are selected and tested. `docs/workflows.md` covers
the measurement workflow.

## License

MIT. See [LICENSE](LICENSE).