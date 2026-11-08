import Foundation

struct BackendFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
protocol DeviceBackend: AnyObject {
    var onEvent: (([String: Any]) -> Void)? { get set }
    var onExit: (() -> Void)? { get set }
    func start(preview: Bool, allowSigning: Bool) throws
    func send(_ command: String, values: [String: Any]) async throws -> [String: Any]
    func shutdown()
    func waitForExit() async
}

extension DeviceBackend {
    func send(_ command: String) async throws -> [String: Any] { try await send(command, values: [:]) }
}

@MainActor
final class Backend: DeviceBackend {
    var onEvent: (([String: Any]) -> Void)?
    var onExit: (() -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var pending: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var buffer = Data()
    private var generation = UUID()

    static func projectRoot() -> URL? {
        if let path = ProcessInfo.processInfo.environment["VIRTUAL_LOCATION_PROJECT"] {
            return URL(fileURLWithPath: path)
        }
        if let path = Bundle.main.infoDictionary?["VLProjectRoot"] as? String {
            return URL(fileURLWithPath: path)
        }
        var path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: path.appendingPathComponent("backend/virtual_location/cli.py").path) { return path }
            path.deleteLastPathComponent()
        }
        return nil
    }

    func start(preview: Bool, allowSigning: Bool) throws {
        guard process == nil else { return }
        guard let root = Self.projectRoot() else { throw BackendFailure(message: "未找到项目目录，请重新构建应用。") }
        let python = root.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw BackendFailure(message: "缺少运行环境，请先在项目目录执行 sh scripts/setup.sh。")
        }
        buffer = Data()
        let proc = Process(), stdin = Pipe(), stdout = Pipe()
        var args = ["-m", "virtual_location.cli", "--state-dir", root.appendingPathComponent(".state").path]
        if preview { args.append("--demo") }
        if allowSigning && !preview { args.append("--allow-apple-signing") }
        args.append("serve")
        proc.executableURL = python
        proc.arguments = args
        proc.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        env["PYTHONPATH"] = root.appendingPathComponent("backend").path
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = FileHandle.nullDevice
        let token = UUID()
        generation = token
        proc.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                self.process = nil
                self.input = nil
                self.failAll("后台已退出；手机定位状态需在设备上确认。")
                self.onExit?()
            }
        }
        try proc.run()
        process = proc
        input = stdin.fileHandleForWriting
        let output = stdout.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            while true {
                let chunk = output.availableData
                if chunk.isEmpty { break }
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.receive(chunk)
                }
            }
            try? output.close()
        }
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        if buffer.count > 1_048_576 {
            shutdown()
            failAll("后台响应超出限制。")
            return
        }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = value["requestId"] as? String, let continuation = pending.removeValue(forKey: id) {
                if value["ok"] as? Bool == true {
                    continuation.resume(returning: value["data"] as? [String: Any] ?? [:])
                } else {
                    continuation.resume(throwing: BackendFailure(message: value["message"] as? String ?? "操作失败"))
                }
            } else if value["event"] != nil {
                onEvent?(value)
            }
        }
    }

    func send(_ command: String, values: [String: Any] = [:]) async throws -> [String: Any] {
        guard let input, process?.isRunning == true else { throw BackendFailure(message: "后台尚未启动。") }
        let id = UUID().uuidString
        var request = values
        request["requestId"] = id
        request["command"] = command
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            do { try input.write(contentsOf: data) }
            catch {
                pending.removeValue(forKey: id)?.resume(throwing: BackendFailure(message: "无法向后台发送请求。"))
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(command == "prepare" ? 780 : 45))
                self?.pending.removeValue(forKey: id)?.resume(throwing: BackendFailure(message: "后台响应超时，请断开后重试。"))
            }
        }
    }

    func shutdown() {
        // EOF gives the backend a chance to clear and release its session.
        try? input?.close()
        input = nil
    }

    func waitForExit() async {
        let current = process
        for _ in 0..<200 {
            if current?.isRunning != true {
                process = nil
                input = nil
                generation = UUID()
                failAll("后台已停止。")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        // SIGTERM is also handled by the backend's cleanup path.
        if current?.isRunning == true { current?.terminate() }
    }

    private func failAll(_ message: String) {
        let callbacks = pending.values
        pending.removeAll()
        for continuation in callbacks { continuation.resume(throwing: BackendFailure(message: message)) }
    }
}
