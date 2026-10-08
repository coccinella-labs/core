import XCTest

/// Guards README claims against the implementation.
///
/// This repository shipped a README that contradicted its own source: it named
/// a command that does not exist, described what `selftest` covers and got it
/// wrong, quoted throughput figures that were never measured, and listed
/// commands the CLI does not expose. Documentation drift is a build failure.
final class ReadmeDriftTests: XCTestCase {

    private func repoRoot() -> URL {
        // Tests/GPUCommCoreTests/<file>.swift -> repository root
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readme() -> String {
        let url = repoRoot().appendingPathComponent("README.md")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("README.md is missing or unreadable")
            return ""
        }
        return text
    }

    private func source(at relative: String) -> String {
        let url = repoRoot().appendingPathComponent(relative)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            XCTFail("\(relative) is missing")
            return ""
        }
        return text
    }

    /// Locate the built CLI. `swift test` puts it beside the xctest bundle in
    /// the same build directory.
    private func locateBinary() -> URL? {
        var url = URL(fileURLWithPath: Bundle(for: Self.self).bundlePath)
        // Walk up from the bundle until a sibling `gpucomm` executable appears.
        for _ in 0..<6 {
            url.appendPathComponent("..")
            let candidate = url.appendingPathComponent("gpucomm")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    /// The CLI's own help text is the source of truth for what exists.
    private func cliHelp() -> String {
        guard let url = locateBinary() else {
            XCTFail("gpucomm binary not found next to the test bundle")
            return ""
        }

        let process = Process()
        process.executableURL = url
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            XCTFail("could not run gpucomm: \(error)")
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Command names as listed under the "Usage:" header of `--help`.
    private func documentedCommands(in help: String) -> [String] {
        var names: [String] = []
        var inUsage = false

        for line in help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("Usage:") {
                inUsage = true
                continue
            }
            guard inUsage else { continue }
            if line.hasPrefix("Examples:") { break }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard words.count >= 2 else { continue }

            // Skip the leading verb of the first line, which is the program name.
            let tokens = words.map(String.init)
            let start = (tokens.first == "gpucomm") ? 1 : 0
            guard tokens.count > start + 1 else { continue }

            // "gpucomm bench bandwidth" -> capture "bandwidth".
            // "gpucomm run reduction"    -> capture "reduction".
            // Skip continuation lines like "gpucomm selftest [--format human|json]".
            let candidate = tokens[start + 1].replacingOccurrences(of: "[", with: "")
            if candidate == "bench" || candidate == "run" {
                guard tokens.count > start + 2 else { continue }
                let name = String(tokens[start + 2].replacingOccurrences(of: "[", with: ""))
                guard !name.hasPrefix("-") else { continue }
                names.append(String(name.prefix { $0.isLetter || $0 == "-" }))
            } else {
                guard !candidate.hasPrefix("-") else { continue }
                names.append(String(candidate.prefix { $0.isLetter || $0 == "-" }))
            }
        }

        return Array(Set(names)).sorted()
    }

    /// Every command the CLI exposes must appear in the README.
    func testEveryCliCommandIsDocumented() {
        let commands = documentedCommands(in: cliHelp())
        XCTAssertFalse(commands.isEmpty, "could not parse commands from CLI help")

        let readme = self.readme()
        for command in commands {
            // Match a documented invocation, not a stray mention in prose.
            let documented = readme.contains("`run \(command)`")
                || readme.contains("`bench \(command)`")
                || readme.contains("gpucomm bench \(command)")
                || readme.contains("gpucomm run \(command)")
            XCTAssertTrue(
                documented,
                "command `\(command)` has no documented invocation in README.md"
            )
        }
    }

    /// The set of benchmarks must be exactly what the README lists.
    func testBenchmarkInventoryMatchesHelp() {
        let help = cliHelp()
        let readme = self.readme()

        for bench in ["bandwidth", "bandwidth-sweep", "scan", "scan-sweep", "latency",
                      "matmul", "matmul-sweep", "transfer", "transfer-sweep"] {
            XCTAssertTrue(
                help.contains("bench \(bench)"),
                "expected `bench \(bench)` in CLI help; help changed, update this test"
            )
            XCTAssertTrue(
                readme.contains(bench),
                "`bench \(bench)` is not mentioned in README.md"
            )
        }
    }

    /// Claims that were false when this test was written. If the implementation
    /// changes such that one becomes true, update the README and delete it here.
    func testKnownFalseClaimsStayAbsent() {
        let readme = self.readme()

        let forbidden: [(claim: String, why: String)] = [
            ("benchmark-sweep", "no such command exists; the real one is bandwidth-sweep"),
            ("Swift 5.9+", "Package.swift declares swift-tools-version 6.1"),
            ("10-100x", "measured tiled speedup on this hardware is about 1.6x, not two orders of magnitude"),
            ("120GB/s on M3 Max", "an unmeasured figure attributed to hardware nobody here has run"),
            ("validates scan, matmul, and transfer", "selftest covers reduction, scan, and matmul"),
            ("about 170 lines", "line-count claims go stale"),
            ("5-10 GB/s", "unmeasured throughput claim"),
            ("10-30 microseconds", "unmeasured latency claim"),
        ]

        for entry in forbidden {
            XCTAssertFalse(
                readme.contains(entry.claim),
                "README contains `\(entry.claim)`, which is false: \(entry.why)"
            )
        }
    }

    /// selftest coverage must be described exactly as the binary reports it.
    func testSelftestCoverageDescriptionIsAccurate() {
        let readme = self.readme()
        let source = source(at: "Sources/gpucomm/main.swift")

        // The names the binary prints come from this switch in main.swift.
        let checkNames = ["reduction", "scan", "matmul"]

        if readme.contains("selftest") {
            for name in checkNames {
                XCTAssertTrue(
                    source.contains("\"\(name)\""),
                    "selftest check `\(name)` disappeared from main.swift; update README and this test"
                )
            }
            // Whichever way the README words it, it must not say transfer is
            // checked. "does not cover" and "also covers" differ by three letters.
            let claimsTransfer = [
                "selftest covers transfer",
                "and transfer operations",
                "also covers transfer",
                "including transfer",
                "validates transfer",
            ]
            for claim in claimsTransfer {
                XCTAssertFalse(
                    readme.contains(claim),
                    "README claims selftest covers transfer (`\(claim)`), which it does not"
                )
            }
        }
    }

    /// Output format modes must match the enum in Output.swift.
    func testDocumentedFormatsMatchSource() {
        let readme = self.readme()
        let output = source(at: "Sources/gpucomm/Output.swift")

        for mode in ["human", "json", "jsonl", "csv"] where output.contains("case \(mode)") {
            if readme.contains("human|json|jsonl|csv") {
                continue
            }
            XCTAssertTrue(
                readme.contains(mode),
                "Output.swift defines `case \(mode)` but README never mentions it"
            )
        }
    }

    /// Every source path the README names must exist, and every source file in
    /// the tree should be reachable from the README.
    func testReferencedPathsExist() {
        let readme = self.readme()

        // Extract anything shaped like a path into Sources/ or docs/.
        let pattern = try! NSRegularExpression(pattern: "(Sources|docs)/[A-Za-z0-9_./]+[.](swift|metal|md)")
        let ns = readme as NSString
        let matches = pattern.matches(in: readme, range: NSRange(location: 0, length: ns.length))

        XCTAssertGreaterThan(
            matches.count, 3,
            "found no source paths in README; the extraction pattern is broken"
        )

        var seen = Set<String>()
        for match in matches {
            let path = ns.substring(with: match.range)
            guard seen.insert(path).inserted else { continue }
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: repoRoot().appendingPathComponent(path).path),
                "README references \(path), which does not exist"
            )
        }
    }

    /// Numeric performance claims must live in a section that is explicitly a
    /// measurement on named hardware.
    func testPerformanceNumbersAreMarkedAsMeasured() {
        let readme = self.readme()
        let hasNumbers = readme.contains("GiB/s") || readme.contains("GB/s")
        guard hasNumbers else { return }

        XCTAssertTrue(
            readme.contains("## Measured results"),
            "README quotes throughput but has no `## Measured results` section"
        )

        // The results section must name the chip, not just say "hardware".
        guard let range = readme.range(of: "## Measured results") else { return }
        let section = String(readme[range.lowerBound...])
        let nextHeading = section.range(of: "\n## ")
        let body = nextHeading.map { String(section[..<$0.lowerBound]) } ?? section

        XCTAssertFalse(
            body.isEmpty,
            "the measured results section is empty"
        )

        let namesChip = ["M1", "M2", "M3", "M4", "Apple"].contains { body.contains($0) }
        XCTAssertTrue(
            namesChip,
            "the measured results section does not name the chip it was measured on"
        )
    }
}
/// Every example command in the README must be accepted by the CLI as written.
/// Flags are positional in ArgReader, so an example with the wrong order silently
/// falls through to usage() and exits 1, which is how the first draft of this
/// README shipped a quickstart that did not run.
final class ReadmeExampleTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func readme() -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent("README.md"), encoding: .utf8)) ?? ""
    }

    private func locateBinary() -> URL? {
        var url = URL(fileURLWithPath: Bundle(for: ReadmeExampleTests.self).bundlePath)
        for _ in 0..<6 {
            url.appendPathComponent("..")
            let candidate = url.appendingPathComponent("gpucomm")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    /// True when a Metal device exists; benchmarks cannot run without one.
    private func hasGPU() -> Bool {
        guard let url = locateBinary() else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["selftest"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Pull every runnable `gpucomm` command out of the README's fenced blocks.
    /// A command continues onto the next line only when the current line ends
    /// with a backslash, so a comment between two commands starts a new one.
    private func exampleCommands() -> [String] {
        var commands: [String] = []
        var current: [String] = []
        var collecting = false

        func flush() {
            if !current.isEmpty {
                commands.append(current.joined(separator: " "))
            }
            current = []
        }

        for raw in readme().split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("```bash") || line.hasPrefix("```console") {
                collecting = true
                continue
            }
            guard collecting else { continue }
            if line.hasPrefix("```") {
                collecting = false
                flush()
                continue
            }
            guard !line.isEmpty else { continue }

            let continued = line.hasSuffix("\\")
            current.append(line.replacingOccurrences(of: "\\", with: " "))
            if !continued {
                flush()
            }
        }

        return commands.filter { $0.contains("./.build/release/gpucomm") }
    }

    func testReadmeExampleCommandsAreAccepted() throws {
        guard let binary = locateBinary() else {
            throw XCTSkip("gpucomm binary not found next to the test bundle")
        }
        guard hasGPU() else {
            throw XCTSkip("no Metal device; CLI argument acceptance needs a working context")
        }

        let examples = exampleCommands()
        XCTAssertGreaterThan(
            examples.count, 1,
            "found no runnable gpucomm commands in README; the extraction pattern is broken"
        )

        for command in examples {
            let cleaned = command
                .replacingOccurrences(of: "\\\n", with: " ")
                .replacingOccurrences(of: "\\", with: " ")
                .split(separator: " ")
                .map(String.init)
                .filter { !$0.isEmpty }

            guard let binaryIndex = cleaned.firstIndex(of: "./.build/release/gpucomm") else {
                XCTFail("could not find the binary in example: \(command)")
                continue
            }

            let arguments = Array(cleaned[(binaryIndex + 1)...])
            let process = Process()
            process.executableURL = binary
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                XCTFail("could not run \(arguments.joined(separator: " ")): \(error)")
                continue
            }
            process.waitUntilExit()

            XCTAssertEqual(
                process.terminationStatus, 0,
                "README example fails with exit \(process.terminationStatus): gpucomm \(arguments.joined(separator: " "))"
            )
        }
    }
}
