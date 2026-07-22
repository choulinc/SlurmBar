import Foundation

/// Runs a subprocess with a timeout, bounded output capture and cooperative cancellation.
///
/// Two details that matter for `ssh` specifically:
///
/// * stdout and stderr are drained concurrently. Reading one to completion before the other
///   deadlocks as soon as the process fills the 64 KiB pipe buffer of the stream nobody is
///   reading — which a large snapshot easily does.
/// * exit is detected from `terminationHandler`, not from waiting on EOF. With
///   `ControlMaster`/`ControlPersist` in the user's SSH config, the persistent master process
///   inherits the pipe and can hold the write end open long after our `ssh` has exited, so
///   waiting for EOF alone would hang. A short grace period after termination collects any
///   final bytes and then gives up on the stragglers.
public enum ProcessRunner {
    /// How long to keep draining after the process exits before concluding that something else
    /// is holding the pipe open.
    static let postExitGrace: TimeInterval = 0.25

    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) async throws -> RemoteCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let state = RunState(limit: maxOutputBytes)
        let startedAt = Date()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<RemoteCommandResult, Error>) in
                state.attach(continuation: continuation, process: process, startedAt: startedAt)

                outputPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.markEOF(.standardOutput)
                    } else {
                        state.append(chunk, to: .standardOutput)
                    }
                }
                errorPipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.markEOF(.standardError)
                    } else {
                        state.append(chunk, to: .standardError)
                    }
                }

                process.terminationHandler = { _ in
                    state.markProcessExited()
                }

                do {
                    try process.run()
                } catch {
                    state.finish(with: .failure(SSHFailure.launchFailed(detail: error.localizedDescription)))
                    return
                }

                state.startTimeout(timeout)
            }
        } onCancel: {
            state.cancel()
        }
    }
}

// MARK: - Internal state

/// All mutable state for one run, behind a lock.
///
/// `terminationHandler`, both readability handlers and the timeout timer all fire on
/// independent queues, and exactly one of them must resume the continuation.
private final class RunState: @unchecked Sendable {
    enum Stream { case standardOutput, standardError }

    private let lock = NSLock()
    private let limit: Int

    private var continuation: CheckedContinuation<RemoteCommandResult, Error>?
    private var process: Process?
    private var startedAt = Date()

    private var outputData = Data()
    private var errorData = Data()
    private var outputTruncated = false

    private var sawOutputEOF = false
    private var sawErrorEOF = false
    private var processExited = false
    private var didFinish = false
    private var didTimeOut = false
    private var didCancel = false

    private var timeoutTimer: DispatchSourceTimer?
    private var graceTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.slurmbar.process-runner")

    init(limit: Int) {
        self.limit = limit
    }

    func attach(
        continuation: CheckedContinuation<RemoteCommandResult, Error>,
        process: Process,
        startedAt: Date
    ) {
        lock.lock()
        self.continuation = continuation
        self.process = process
        self.startedAt = startedAt
        lock.unlock()
    }

    func append(_ chunk: Data, to stream: Stream) {
        lock.lock()
        defer { lock.unlock() }
        switch stream {
        case .standardOutput:
            if outputData.count + chunk.count > limit {
                let room = max(0, limit - outputData.count)
                outputData.append(chunk.prefix(room))
                outputTruncated = true
                // Past the cap the remote side is misbehaving; stop it rather than keep reading.
                process?.terminate()
            } else {
                outputData.append(chunk)
            }
        case .standardError:
            // stderr is only ever shown as a message, so a much smaller cap is plenty.
            if errorData.count < 64 * 1024 {
                errorData.append(chunk.prefix(64 * 1024 - errorData.count))
            }
        }
    }

    func markEOF(_ stream: Stream) {
        lock.lock()
        switch stream {
        case .standardOutput: sawOutputEOF = true
        case .standardError: sawErrorEOF = true
        }
        let ready = processExited && sawOutputEOF && sawErrorEOF && !didFinish
        lock.unlock()
        if ready { finishWithProcessResult() }
    }

    func markProcessExited() {
        lock.lock()
        processExited = true
        let ready = sawOutputEOF && sawErrorEOF && !didFinish
        lock.unlock()

        if ready {
            finishWithProcessResult()
            return
        }
        // Give the pipes a moment to deliver their tail, then stop waiting: a persistent
        // ControlMaster may keep the write end open indefinitely.
        scheduleGraceTimer()
    }

    private func scheduleGraceTimer() {
        lock.lock()
        guard graceTimer == nil, !didFinish else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + ProcessRunner.postExitGrace)
        timer.setEventHandler { [weak self] in
            self?.finishWithProcessResult()
        }
        graceTimer = timer
        lock.unlock()
        timer.resume()
    }

    func startTimeout(_ timeout: TimeInterval) {
        guard timeout > 0 else { return }
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.handleTimeout(timeout)
        }
        timeoutTimer = timer
        lock.unlock()
        timer.resume()
    }

    private func handleTimeout(_ timeout: TimeInterval) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didTimeOut = true
        let process = self.process
        lock.unlock()

        terminateHard(process)
        finish(with: .failure(SSHFailure.timedOut(seconds: timeout)))
    }

    func cancel() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        didCancel = true
        let process = self.process
        lock.unlock()

        terminateHard(process)
        finish(with: .failure(SSHFailure.cancelled))
    }

    private func terminateHard(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        // SIGTERM is enough for ssh in practice; escalate only if it is still alive shortly after.
        queue.asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
    }

    private func finishWithProcessResult() {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }
        let exitCode = process?.terminationStatus ?? -1
        let output = outputData
        let errorText = String(decoding: errorData, as: UTF8.self)
        let elapsed = Date().timeIntervalSince(startedAt)
        let truncated = outputTruncated
        lock.unlock()

        if truncated {
            finish(with: .failure(SSHFailure.protocolFailure(
                .payloadTooLarge(bytes: output.count, limit: limit)
            )))
            return
        }

        finish(with: .success(RemoteCommandResult(
            exitCode: exitCode,
            standardOutput: output,
            standardError: errorText,
            duration: elapsed
        )))
    }

    func finish(with result: Result<RemoteCommandResult, Error>) {
        lock.lock()
        guard !didFinish, let continuation else {
            lock.unlock()
            return
        }
        didFinish = true
        self.continuation = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
        graceTimer?.cancel()
        graceTimer = nil
        lock.unlock()

        continuation.resume(with: result)
    }
}
