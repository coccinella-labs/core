<p align="center">
  <img src="https://raw.githubusercontent.com/coccinella-labs/core/main/.github/assets/thumbnail.png" alt="core" width="100%">
</p>

# Core

Core is a low-level GPU compute runtime for Apple Silicon built on Metal. It focuses on memory behavior, synchronization patterns, and data movement efficiency on modern Apple GPUs. The project is organized around experimental kernels and benchmarks that measure bandwidth, latency, and communication patterns, with built-in correctness checks and output formats for systematic measurement across hardware configurations.

Status: Active experiments. Benchmarks validated. CI ensures builds remain stable. Hardware reliability depends on direct measurement on target machines.

## Getting Started

Core requires macOS with Apple Silicon, Swift 5.9+, and Xcode. Build the release binary with `swift build -c release`. The build produces a CLI tool at `.build/release/gpucomm` that runs benchmarks and correctness tests.

To measure GPU bandwidth on your machine, run `./.build/release/gpucomm bench bandwidth --size-mib 64 --iters 200 --mode shared` to test shared memory mode or `--mode private` for memory local to the GPU. For a sweep across multiple sizes that shows scaling behavior, use `bandwidth-sweep` instead, e.g., `./.build/release/gpucomm bench bandwidth-sweep --sizes-mib 1,4,16,64 --iters 200 --mode private --format jsonl`. Output defaults to human-readable text; pass `--format json` or `--format jsonl` to capture structured data for logging or analysis.

To run correctness checks on your GPU before running benchmarks, execute `./.build/release/gpucomm selftest`. This validates scan, matmul, and transfer operations on small problem sizes. To list all available benchmarks and options, run `./.build/release/gpucomm --help`.

For development, ensure pre-commit hooks are installed with `pre-commit install` and run them before committing with `pre-commit run --all-files`.

## Architecture

Core is structured around three layers. At the bottom is the Metal runtime abstraction split across `Sources/GPUCommCore/MetalContext.swift`, which manages devices, command queues, and pipelines, and `Sources/GPUCommCore/KernelLibrary.swift`, which compiles kernels at startup. Above that sits the benchmark layer at `Sources/GPUCommCore/Benchmarks/`, with one file per experiment covering bandwidth, latency, scan, matmul, transfer, and reduction operations. The Metal kernels themselves live in `Sources/GPUCommCore/Resources/Kernels/` and are compiled at runtime when the CLI starts. At the top is the CLI at `Sources/gpucomm`, which parses arguments, dispatches to the appropriate benchmark, formats results, and handles measurement aggregation.

The design philosophy is that experiments should be measurable and reproducible. Every benchmark accepts parameters for problem size, iteration count, warmup count, and repetition count. Results can be aggregated across multiple runs to compute percentiles (p50, p95) and track variability. All kernels include correctness checks for small problem sizes; this is especially important for scan and matmul, where silent numerical errors are easy to miss.

Key code anchors are `Sources/GPUCommCore/MetalContext.swift` (device and queue management), `Sources/GPUCommCore/Benchmarks/` (benchmark implementations), `Sources/GPUCommCore/Resources/Kernels/` (Metal kernel source), and `Sources/gpucomm/main.swift` (CLI entry point). Output formatting is centralized in `Sources/gpucomm/Output.swift` (text, JSON, JSONL, CSV modes) with percentile aggregation in `Sources/gpucomm/Stats.swift`.

## Understanding Results

GPU benchmarks are only reliable when measured on real hardware with consistent conditions. Results vary by chip (M1, M2, M3, etc.), GPU core count, memory configuration, and system load. The same benchmark run twice can produce different results due to thermal throttling, background processes, or battery mode. This is not a bug; it's why systematic measurement with warmup counts, repetitions, and percentile reporting matters.

When running benchmarks, disable power management features if possible (plug in, avoid low-power mode, close other applications). Run each benchmark multiple times with `--reps` to capture variance. Always record metadata: chip name and GPU core count (from `system_profiler SPHardwareDataType`), macOS version (`sw_vers`), Xcode version (`xcodebuild -version`), and the exact command line used. This metadata is essential for interpreting results and tracking regressions across Swift/Xcode updates or macOS releases.

GitHub Actions CI can validate that the code builds and basic CLI operations work, but it cannot measure true GPU performance because CI runners are shared and lack a dedicated GPU. For real results, run benchmarks locally and report them back to the repository with your hardware metadata.

## Reporting Results and Issues

When posting benchmark results in GitHub issues or comments, include hardware details, OS/tooling versions, the commit SHA, and the command line used. Before running experiments, capture your system state with a quick sanity check: `git rev-parse HEAD` for the commit, `sw_vers` for macOS, `xcodebuild -version` for Xcode, and `system_profiler SPHardwareDataType | head -n 30` for chip and GPU details.

A typical result report looks like this. Run a bandwidth sweep with `benchmark-sweep --sizes-mib 1,4,16,64 --iters 200 --reps 5 --mode private --format jsonl` to capture p50/p95 percentiles across five repetitions. Save the JSON output. Include the command, the hardware (e.g., "M3 Max with 12-core GPU on macOS 15.1"), and the output file as a comment in the issue. This lets others compare across machines and track regressions.

For correctness concerns, run `selftest` first to isolate whether the issue is in the kernel or in measurement. If a benchmark crashes or produces nonsensical results, include the exact command line, the error message, and your hardware metadata so maintainers can reproduce it.

## Roadmap

The main roadmap is tracked in GitHub issue #1 with detailed comments at each milestone. Core has implemented transfer benchmarks with bandwidth and latency measurement, single-block and multi-block scan kernels with correctness validation, naive and tiled matmul implementations with a sweep across tile sizes and problem sizes, latency measurements for kernel launch overhead, and output formatting for both human-readable and machine-parseable results. All benchmarks support `--reps` for aggregating results across multiple runs and computing percentiles.

Current work focuses on optimizing specific kernels and validating that the baseline measurements hold across the full range of Apple Silicon chips. Future directions include communication pattern experiments (allreduce, allgather), mixed-precision kernels, and integration with higher-level frameworks. See issue #1 for the full list of completed milestones and next steps.

## Build and Run

Building requires only `swift build -c release`. The resulting binary at `.build/release/gpucomm` includes all benchmarks and the CLI. No external dependencies are needed; Core uses only Swift, Metal, and Foundation.

Common benchmarks are bandwidth measurement (`bench bandwidth`), bandwidth scaling across sizes (`bench bandwidth-sweep`), latency (`bench latency`), scan-based prefix sum (`bench scan`, `bench scan-sweep`), matrix multiplication (`bench matmul`, `bench matmul-sweep`), data transfer between CPU and GPU (`bench transfer`, `bench transfer-sweep`), and correctness validation (`selftest`). Each benchmark accepts parameters for problem size, iteration count, warmup count, repetitions, and output format. Run `./.build/release/gpucomm --help` to see all available commands and options.

## Known Limitations

Benchmarks measure timings in CPU nanoseconds via Metal's timestamp query, which has microsecond granularity on Apple Silicon. Very short operations (< 1 microsecond) may show noise or inaccuracy. Warmup is essential; the first few kernel launches typically have higher latency due to GPU state initialization. Memory bandwidth measurements assume no other GPU workload is running; background rendering or other GPU tasks will interfere with results.

Correctness checks are implemented for scan and matmul but not for transfer operations. Transfer validates that data round-trips successfully (CPU → GPU → CPU) but does not check against a reference implementation. Latency measurement includes GPU queue submission overhead but not CPU-side scheduling jitter. Very large problem sizes (> 1GB) may be limited by available GPU VRAM; the default GPU memory limit is typically 50% of system RAM on Apple Silicon.

## Contributing

Fork the repository, create a feature branch, make changes to `Sources/GPUCommCore` or `Sources/gpucomm`, add tests as appropriate, run `pre-commit run --all-files` to lint, and open a PR. When adding a new benchmark, implement it as a new file in `Sources/GPUCommCore/Benchmarks/`, add a command to the CLI dispatcher in `main.swift`, and include correctness checks for at least one small problem size.

When adding a new Metal kernel, place the source in `Sources/GPUCommCore/Resources/Kernels/`, implement a corresponding benchmark function, and test it locally on your hardware before opening a PR. Document the kernel's purpose, the problem size parameters it accepts, and any known limitations (e.g., maximum thread group size, memory requirements).

## Performance and Scaling

Bandwidth typically scales from a few GB/s at small transfer sizes up to the theoretical maximum for your GPU (e.g., 120GB/s on M3 Max) at large sizes. Latency for kernel launch is typically 10-30 microseconds. Scan throughput scales with GPU core count and problem size; very large scans (millions of elements) are compute-bound. Matmul performance depends heavily on tile size and data reuse; tiled variants outperform naive implementations by 10-100x depending on problem size.

Results will vary based on system load, thermal state, and background processes. Always run multiple repetitions and report percentiles, not just peak values. If results seem inconsistent, disable automatic power management, close other applications, and re-run.

## Related Documentation

AGENTS.md documents how GPU communication patterns are selected and tested. docs/workflows.md covers the development and measurement workflow. The Metal kernels in `Sources/GPUCommCore/Resources/Kernels/` are documented inline with comments on algorithm and memory access patterns.

## License

MIT. See LICENSE file.

## Contact

Questions? Open an issue on GitHub or comment on the main roadmap issue (#1) with your hardware details and measurements.
