import Foundation

/// Real binary relay transport. The runtime adapter supplies the process; this
/// layer owns only protocol/pipe lifetime and never invokes a container command.
final class GitCredentialRelayChannel: GitCredentialBrokerChannel, @unchecked Sendable {
    /// Broker exit is bounded; a relay cancel that cannot reap must return.
    static let cancelBound: TimeInterval = 1.5
    private let process: CredentialDuplexProcess
    private let generation: UInt64
    private let lock = NSLock()
    private var started = false
    init(process: CredentialDuplexProcess, platform: String, generation: UInt64) throws {
        self.process = process; self.generation = generation
        guard generation != 0, ["linux/arm64", "linux/amd64"].contains(platform) else { throw GitCredentialFailure.invalidContext }
        var decoder = GitCredentialFrameDecoder()
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while let chunk = try process.read(deadline: deadline) {
            let frames = try decoder.append(chunk)
            if !frames.isEmpty {
                guard frames.count == 1, decoder.isEmpty, frames[0] == GitCredentialFrame(operation: .hello, request: 0, generation: generation, fields: [.platform: platform]) else { throw GitCredentialFailure.invalidMessage }
                try process.send(GitCredentialProtocol.encode(frames[0]))
                GitCredentialDiag.event("channel.hello", "bytes=\(chunk.count)"); return
            }
        }
        GitCredentialDiag.event("channel.hello_missing")
        throw GitCredentialFailure.transport
    }
    func start(receive: @escaping @Sendable (GitCredentialFrame) -> Void, disconnected: @escaping @Sendable () -> Void) {
        lock.lock(); guard !started else { lock.unlock(); return }; started = true; lock.unlock()
        GitCredentialDiag.event("channel.start")
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { GitCredentialDiag.event("channel.stop"); process.cancel(); disconnected() }
            var decoder = GitCredentialFrameDecoder()
            var partialSince: TimeInterval?
            while true {
                do {
                    let now = ProcessInfo.processInfo.systemUptime
                    if let partialSince, now - partialSince >= 15 { GitCredentialDiag.event("channel.partial_timeout"); return }
                    guard let chunk = try process.read(deadline: now + 1, cancelOnTimeout: false) else { GitCredentialDiag.event("channel.eof"); return }
                    GitCredentialDiag.event("channel.chunk", "bytes=\(chunk.count)")
                    for frame in try decoder.append(chunk) {
                        let kind = frame.operation == .get ? "get" : frame.operation == .erase ? "erase" : "other"
                        let accepted = frame.generation == generation && frame.request != 0 && (frame.operation == .get || frame.operation == .erase)
                        GitCredentialDiag.event("channel.frame", "kind=\(kind) req=\(frame.request) gen_match=\(frame.generation == generation) keys=\(frame.fields.count) accepted=\(accepted)")
                        guard accepted else { GitCredentialDiag.event("channel.reject"); return }
                        receive(frame)
                    }
                    if decoder.isEmpty { partialSince = nil } else if partialSince == nil { partialSince = now }
                } catch GitCredentialFailure.deadline { continue }
                catch { GitCredentialDiag.event("channel.error", "code=\((error as? GitCredentialFailure)?.diagnosticCode ?? "other")"); return }
            }
        }
    }
    func send(_ frame: GitCredentialFrame) throws {
        guard frame.operation == .reply, frame.generation == generation, frame.request != 0 else {
            GitCredentialDiag.event("channel.send_reject", "req=\(frame.request) gen_match=\(frame.generation == generation)")
            throw GitCredentialFailure.invalidMessage
        }
        let bytes = try GitCredentialProtocol.encode(frame)
        GitCredentialDiag.event("channel.send", "bytes=\(bytes.count) keys=\(frame.fields.count) req=\(frame.request)")
        try process.send(bytes)
    }
    func cancel() { process.cancel(deadline: ProcessInfo.processInfo.systemUptime + Self.cancelBound) }
}
