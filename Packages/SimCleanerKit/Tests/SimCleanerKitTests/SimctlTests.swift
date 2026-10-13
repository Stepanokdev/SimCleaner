//
//  SimctlTests.swift
//  SimCleanerKitTests
//

import Foundation
import Testing
@testable import SimCleanerKit

struct SimctlParsingTests {
    @Test func devicesKeepTheirRuntimeAndState() throws {
        let json = """
        {"devices":{
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
            {"udid":"A","name":"iPhone 18 Pro","state":"Booted","isAvailable":true,"dataPathSize":5110000000,"lastUsedAt":"2026-10-08T07:12:01Z","deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"}
          ],
          "com.apple.CoreSimulator.SimRuntime.iOS-16-4":[
            {"udid":"B","name":"Old","state":"Shutdown","isAvailable":false,"availabilityError":"runtime profile not found"}
          ]
        }}
        """
        let devices = try SimctlClient.decodeDevices(Data(json.utf8))
        let booted = try #require(devices.first { $0.udid == "A" })
        #expect(booted.deviceState == .booted)
        #expect(booted.runtimeIdentifier == "com.apple.CoreSimulator.SimRuntime.iOS-27-0")
        #expect(booted.dataPathSize == 5_110_000_000)
        let old = try #require(devices.first { $0.udid == "B" })
        #expect(old.isAvailable == false)
        #expect(old.availabilityError == "runtime profile not found")
    }

    @Test func runtimeImagesAreKeyedByTheirDeletableID() throws {
        let json = """
        {"CDB524A5-15AC-46F3-BAFB-5571941803F3":{"build":"24A434","deletable":true,"kind":"Patchable Cryptex Disk Image","lastUsedAt":"2026-10-07T06:30:32Z","runtimeIdentifier":"com.apple.CoreSimulator.SimRuntime.iOS-27-0","sizeBytes":8070000000,"state":"Ready","version":"27.0"}}
        """
        let images = try SimctlClient.decodeRuntimeImages(Data(json.utf8))
        let image = try #require(images.first)
        #expect(image.identifier == "CDB524A5-15AC-46F3-BAFB-5571941803F3")
        #expect(image.platform == .iOS)
        #expect(image.sizeBytes == 8_070_000_000)
        #expect(image.lastUsedDate != nil)
        #expect(image.displayName == "iOS 27.0 (24A434)")
    }

    @Test func errorsKeepTheReadableLineAndTheCoreSimulatorCode() {
        let stderr = "An error was encountered processing the command (domain=com.apple.CoreSimulator.SimError, code=405):\nUnable to lookup in current state: Shutdown\n"
        #expect(SimctlClient.message(from: stderr) == "Unable to lookup in current state: Shutdown")
        #expect(SimctlClient.coreSimulatorCode(in: stderr) == 405)
        #expect(SimctlError.commandFailed(command: "install", status: 149, message: "x", code: 405).isWrongDeviceState)
        #expect(SimctlClient.message(from: "xcrun: error: cannot be used within an App Sandbox.\n") == "xcrun: error: cannot be used within an App Sandbox.")
    }

    @Test func badJSONIsAnErrorNotAnEmptyList() {
        #expect(throws: SimctlError.unreadableOutput(command: "list devices")) {
            _ = try SimctlClient.decodeDevices(Data("Usage: simctl".utf8))
        }
    }

    @Test func deviceStatesMapFromBothSources() {
        #expect(DeviceState(simctl: "Shutting Down") == .shuttingDown)
        #expect(DeviceState(plistValue: 3) == .booted)
        #expect(DeviceState(plistValue: 1) == .shutdown)
        #expect(DeviceState(simctl: "Booted").isRunning)
        #expect(!DeviceState(simctl: "Shutdown").isRunning)
    }
}

struct SimctlLocatorTests {
    /// Xcode 27.0's Developer/usr/bin/simctl, trimmed to the lines that matter.
    private let xcode27Wrapper = """
    #!/bin/bash
    EXPECTED_VERSION="1171.7"
    CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/Info.plist" 2>/dev/null)"
    if [[ -z "${CURRENT_VERSION}" ]]; then
        "${DEVELOPER_DIR}/usr/bin/xcodebuild" -runFirstLaunch >&2
    fi
    exec "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl" "${@}"
    """
    private let developer = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer")

    @Test func wrapperIsFollowedWhenCoreSimulatorIsNewEnough() throws {
        let result = SimctlLocator.wrapperTarget(script: xcode27Wrapper, developer: developer) { _ in "1171.7" }
        // The binary must exist for the success path; on a Mac without Xcode 27 this reports setup instead.
        if FileManager.default.isExecutableFile(atPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl") {
            let tool = try result.get()
            #expect(tool.source == .coreSimulatorFramework)
            #expect(tool.developerDirectory == developer)
            #expect(tool.environment["DEVELOPER_DIR"] == developer.path)
        } else {
            #expect(throws: SimctlUnavailable.self) { _ = try result.get() }
        }
    }

    @Test func olderCoreSimulatorMeansXcodeNeedsSetup() {
        let result = SimctlLocator.wrapperTarget(script: xcode27Wrapper, developer: developer) { _ in "1107.0" }
        #expect(result == .failure(.coreSimulatorNeedsSetup(installed: "1107.0", required: "1171.7")))
        let missing = SimctlLocator.wrapperTarget(script: xcode27Wrapper, developer: developer) { _ in nil }
        #expect(missing == .failure(.coreSimulatorNeedsSetup(installed: nil, required: "1171.7")))
    }

    @Test func unknownScriptsAreUnsupportedRatherThanGuessed() {
        let result = SimctlLocator.wrapperTarget(script: "#!/bin/sh\nexec /usr/local/bin/simctl \"$@\"\n", developer: developer) { _ in "9999" }
        #expect(result == .failure(.unsupportedToolchain("unrecognized simctl script")))
        let elsewhere = SimctlLocator.wrapperTarget(script: "EXPECTED_VERSION=\"1\"\nexec \"/tmp/evil/simctl\" \"$@\"", developer: developer) { _ in "2" }
        #expect(elsewhere == .failure(.unsupportedToolchain("simctl script points outside CoreSimulator")))
    }

    @Test func versionStringsCompareLikeXcodeDoes() {
        #expect(!VersionString.isOlder("1107.0", than: "1107"))
        #expect(VersionString.isOlder("1107", than: "1171.7"))
        #expect(!VersionString.isOlder("1171.7", than: "1171.7"))
        #expect(!VersionString.isOlder("1172", than: "1171.7"))
    }

    @Test func commandLineToolsAreReportedAsSuch() async {
        let runner = StubRunner(stdout: "/Library/Developer/CommandLineTools\n")
        let result = await SimctlLocator.locateInsideSandbox(runner: runner, override: nil)
        if ProcessInfo.processInfo.environment["DEVELOPER_DIR"] == nil {
            #expect(result == .failure(.commandLineToolsOnly("/Library/Developer/CommandLineTools")))
        }
    }
}

/// Answers every command with the same output.
struct StubRunner: CommandRunning {
    var status: Int32 = 0
    var stdout = ""
    var stderr = ""

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult {
        CommandResult(status: status, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8))
    }
}

struct ProcessRunnerTests {
    @Test func capturesBothStreamsAndTheExitStatus() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo out; echo err >&2; exit 3"], timeout: 10)
        #expect(result.status == 3)
        #expect(result.stdoutText == "out\n")
        #expect(result.stderrText == "err\n")
        #expect(!result.timedOut)
    }

    @Test func argumentsAreNotInterpretedByAShell() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/echo"), arguments: ["$(whoami); rm -rf /"], timeout: 10)
        #expect(result.stdoutText == "$(whoami); rm -rf /\n")
    }

    @Test func slowCommandsTimeOut() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(!result.succeeded)
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes 0123456789abcdef | head -c 3000000; yes x | head -c 300000 >&2"], timeout: 20)
        #expect(result.stdout.count == 3_000_000)
        #expect(result.stderr.count == 300_000)
    }
}
