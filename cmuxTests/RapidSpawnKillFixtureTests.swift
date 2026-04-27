import XCTest

final class RapidSpawnKillFixtureTests: XCTestCase {
    private struct ProcessResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    func testRapidSpawnKillFixtureKeepsIOSurfaceFootprintUnderBudget() throws {
        let repositoryRoot = try Self.repositoryRoot()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("tests/fixtures/rapid_spawn_kill.sh")

        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: fixtureURL.path),
            "Expected executable fixture at \(fixtureURL.path)"
        )

        let appURL = try Self.cmuxAppURL()
        let thresholdMB = ProcessInfo.processInfo.environment["CMUX_RAPID_SPAWN_KILL_IOSURFACE_LIMIT_MB"]
            .flatMap(Double.init) ?? 50
        let result = runProcess(
            executablePath: "/usr/bin/leaks",
            arguments: [
                "--atExit",
                "--",
                "/bin/bash",
                fixtureURL.path,
            ],
            environment: [
                "CMUX_RAPID_SPAWN_KILL_APP_PATH": appURL.path,
                "CMUX_RAPID_SPAWN_KILL_ITERATIONS": "3",
                "CMUX_RAPID_SPAWN_KILL_FORCE_WINDOW": "1",
                "CMUX_RAPID_SPAWN_KILL_READY_TIMEOUT_MS": "8000",
            ],
            timeout: 90
        )

        let combinedOutput = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let attachment = XCTAttachment(string: combinedOutput)
        attachment.name = "rapid-spawn-kill-leaks-output"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertFalse(result.timedOut, combinedOutput)
        XCTAssertEqual(result.status, 0, combinedOutput)

        let measuredMB = try XCTUnwrap(
            Self.parseIOSurfaceFootprintMB(from: combinedOutput),
            "Expected fixture output to include 'VM: IOSurface = <N> MB'. Output:\n\(combinedOutput)"
        )
        XCTAssertGreaterThan(
            measuredMB,
            0,
            "Expected rapid_spawn_kill.sh to force an IOSurface allocation. Output:\n\(combinedOutput)"
        )
        XCTAssertLessThanOrEqual(
            measuredMB,
            thresholdMB,
            "VM: IOSurface exceeded \(thresholdMB) MB after rapid spawn/kill loop. Output:\n\(combinedOutput)"
        )
    }

    private static func repositoryRoot(filePath: String = #filePath) throws -> URL {
        var url = URL(fileURLWithPath: filePath)
        while url.path != "/" {
            let candidate = url
                .deletingLastPathComponent()
                .appendingPathComponent("GhosttyTabs.xcodeproj")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return url.deletingLastPathComponent()
            }
            url.deleteLastPathComponent()
        }
        throw XCTSkip("Unable to locate repository root from \(filePath)")
    }

    private static func cmuxAppURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment

        if let override = environment["CMUX_RAPID_SPAWN_KILL_APP_PATH"], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        if let testHost = environment["TEST_HOST"], !testHost.isEmpty,
           let appURL = enclosingAppBundle(for: URL(fileURLWithPath: testHost)) {
            return appURL
        }

        if let builtProductsDir = environment["BUILT_PRODUCTS_DIR"], !builtProductsDir.isEmpty {
            let appURL = URL(fileURLWithPath: builtProductsDir)
                .appendingPathComponent("cmux DEV.app")
            if FileManager.default.fileExists(atPath: appURL.path) {
                return appURL
            }
        }

        if let appURL = enclosingAppBundle(for: Bundle.main.bundleURL) {
            return appURL
        }

        throw XCTSkip("Unable to locate built cmux app bundle for rapid_spawn_kill.sh")
    }

    private static func enclosingAppBundle(for url: URL) -> URL? {
        var current = url
        while current.path != "/" {
            if current.pathExtension == "app" && FileManager.default.fileExists(atPath: current.path) {
                return current
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private static func parseIOSurfaceFootprintMB(from output: String) -> Double? {
        let pattern = #"VM: IOSurface\s*=\s*([0-9]+(?:\.[0-9]+)?)\s*MB"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        guard
            let match = regex.firstMatch(in: output, range: range),
            let valueRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }
        return Double(output[valueRange])
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> ProcessResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }
        process.environment = mergedEnvironment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessResult(
                status: -1,
                stdout: "",
                stderr: String(describing: error),
                timedOut: false
            )
        }

        let exitSignal = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            process.waitUntilExit()
            exitSignal.signal()
        }

        let timedOut = exitSignal.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = exitSignal.wait(timeout: .now() + 2)
        }

        return ProcessResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
