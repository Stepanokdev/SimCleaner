//
//  ProcessRunner.swift
//  SimCleanerKit
//

import Foundation

/// What a finished command printed and how it exited.
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public let timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool = false) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs an executable directly, never through a shell, so arguments are passed exactly as given.
public protocol CommandRunning: Sendable {
    func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult
}

public extension CommandRunning {
    func run(_ executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 60) async throws -> CommandResult {
        try await run(executable, arguments: arguments, environment: environment, standardInput: nil, timeout: timeout)
    }
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult {
        let execution = ProcessExecution(executable: executable, arguments: arguments, environment: environment, standardInput: standardInput, timeout: timeout)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try execution.runToCompletion() })
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }
}

/// One child process. Reads both pipes while the child runs so a chatty command can't fill a pipe
/// buffer and stall, and terminates the child on timeout or cancellation.
private final class ProcessExecution: @unchecked Sendable {
    private let process = Process()
    private let standardInput: Data?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false

    init(executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) {
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        self.standardInput = standardInput
        self.timeout = timeout
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        if process.isRunning { process.terminate() }
    }

    func runToCompletion() throws -> CommandResult {
        let output = Pipe()
        let errors = Pipe()
        let input = standardInput.map { _ in Pipe() }
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = input ?? FileHandle.nullDevice

        let readers = DispatchGroup()
        let stdout = DataBox()
        let stderr = DataBox()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdout.data = output.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderr.data = errors.fileHandleForReading.readDataToEndOfFile()
            readers.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        lock.lock()
        let alreadyCancelled = cancelled
        lock.unlock()
        if alreadyCancelled { throw CancellationError() }

        do {
            try process.run()
        } catch {
            // The pipes' write ends are still ours; close them so the readers finish.
            try? output.fileHandleForWriting.close()
            try? errors.fileHandleForWriting.close()
            readers.wait()
            throw error
        }

        if let standardInput, let input {
            input.fileHandleForWriting.write(standardInput)
            try? input.fileHandleForWriting.close()
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                exited.wait()
            }
        }
        readers.wait()

        lock.lock()
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }

        return CommandResult(status: process.terminationStatus, stdout: stdout.data, stderr: stderr.data, timedOut: timedOut)
    }
}

/// Written by one reader thread, read only after `DispatchGroup.wait()` returns.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
