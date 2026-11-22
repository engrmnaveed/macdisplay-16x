import Foundation

/// Where the app keeps its files. Everything lives in one folder under Application Support.
public struct AppPaths: Sendable {
    public static let bundleIdentifier = "com.16xbrains.macdisplay16x"
    public static let productName = "Display 16X"
    public static let version = "0.1.0"

    public let supportDirectory: URL

    public init(supportDirectory: URL? = nil) {
        if let supportDirectory {
            self.supportDirectory = supportDirectory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            self.supportDirectory = base.appendingPathComponent(AppPaths.bundleIdentifier, isDirectory: true)
        }
    }

    public var settingsFile: URL { supportDirectory.appendingPathComponent("settings.json") }
    public var recoveryFile: URL { supportDirectory.appendingPathComponent("recovery.json") }
    public var socketPath: String { supportDirectory.appendingPathComponent("ipc.sock").path }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

// MARK: Messages

public struct IPCRequest: Codable, Sendable, Equatable {
    public var version: Int
    public var command: Command

    public init(command: Command) {
        self.version = IPCCodec.version
        self.command = command
    }
}

public struct IPCResponse: Codable, Sendable, Equatable {
    public var version: Int
    public var result: CommandResult

    public init(result: CommandResult) {
        self.version = IPCCodec.version
        self.result = result
    }
}

/// One JSON object per line in each direction.
public enum IPCCodec {
    public static let version = 1

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

public enum IPCError: Error, Sendable, Equatable {
    case appNotRunning
    case timeout
    case pathTooLong
    case system(String)
    case invalidResponse(String)

    public var message: String {
        switch self {
        case .appNotRunning: "Display 16X is not running. Start the app, then try again."
        case .timeout: "Display 16X did not answer in time."
        case .pathTooLong: "The path to the app's socket is too long for this system."
        case .system(let detail): "The connection to Display 16X failed (\(detail))."
        case .invalidResponse(let detail): "Display 16X sent an answer that could not be read (\(detail))."
        }
    }
}

// MARK: Socket plumbing

enum UnixSocket {
    static func address(for path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in bytes.enumerated() { buffer[index] = byte }
            buffer[bytes.count] = 0
        }
        return address
    }

    static func setTimeout(_ descriptor: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - seconds.rounded(.down)) * 1_000_000))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func writeAll(_ descriptor: Int32, _ data: Data) -> Bool {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written <= 0 { return false }
            offset += written
        }
        return true
    }

    /// Reads up to the first newline. Returns nil on a timeout or when the peer sent nothing.
    static func readLine(_ descriptor: Int32, limit: Int = 4 * 1024 * 1024) -> (data: Data?, timedOut: Bool) {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while collected.count < limit {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0 {
                let timedOut = errno == EAGAIN || errno == EWOULDBLOCK
                return (nil, timedOut)
            }
            if count == 0 { break }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                collected.append(contentsOf: buffer[..<newline])
                return (collected, false)
            }
            collected.append(contentsOf: buffer[..<count])
        }
        return (collected.isEmpty ? nil : collected, false)
    }
}

/// The CLI's side: one request, one answer, with a timeout.
public struct UnixSocketClient: Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func send(_ payload: Data, timeout: TimeInterval) throws(IPCError) -> Data {
        guard var address = UnixSocket.address(for: path) else { throw .pathTooLong }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .system(String(cString: strerror(errno))) }
        defer { close(descriptor) }
        UnixSocket.setTimeout(descriptor, seconds: timeout)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            if errno == ENOENT || errno == ECONNREFUSED { throw .appNotRunning }
            throw .system(String(cString: strerror(errno)))
        }
        guard UnixSocket.writeAll(descriptor, payload + Data([0x0A])) else { throw .system("the request could not be sent") }
        let answer = UnixSocket.readLine(descriptor)
        if answer.timedOut { throw .timeout }
        guard let data = answer.data else { throw .invalidResponse("empty answer") }
        return data
    }

    /// True when something is listening on the socket.
    public var isServerAlive: Bool {
        guard var address = UnixSocket.address(for: path) else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        UnixSocket.setTimeout(descriptor, seconds: 1)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    /// Sends one command and returns its result.
    public func execute(_ command: Command, timeout: TimeInterval) throws(IPCError) -> CommandResult {
        let payload: Data
        do {
            payload = try IPCCodec.encode(IPCRequest(command: command))
        } catch {
            throw .system("the command could not be encoded")
        }
        let answer = try send(payload, timeout: timeout)
        do {
            return try IPCCodec.decode(IPCResponse.self, from: answer).result
        } catch {
            throw .invalidResponse(String(describing: error))
        }
    }
}

/// The app's side. It wakes only when a client connects, and only serves the user who owns it.
public final class UnixSocketServer: @unchecked Sendable {
    private let path: String
    private let handler: @Sendable (Data) async -> Data
    private let queue = DispatchQueue(label: AppPaths.bundleIdentifier + ".ipc")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String, handler: @escaping @Sendable (Data) async -> Data) {
        self.path = path
        self.handler = handler
    }

    public func start() throws(IPCError) {
        guard var address = UnixSocket.address(for: path) else { throw .pathTooLong }
        unlink(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw .system(String(cString: strerror(errno))) }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let detail = String(cString: strerror(errno))
            close(descriptor)
            throw .system(detail)
        }
        chmod(path, 0o600)
        guard listen(descriptor, 8) == 0 else {
            let detail = String(cString: strerror(errno))
            close(descriptor)
            throw .system(detail)
        }
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        listener = descriptor
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    public func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            listener = -1
        }
        unlink(path)
    }

    private func acceptPending() {
        while listener >= 0 {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == getuid() else {
            close(client)
            return
        }
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
        UnixSocket.setTimeout(client, seconds: 5)
        let handler = self.handler
        DispatchQueue.global(qos: .userInitiated).async {
            guard let request = UnixSocket.readLine(client).data else {
                close(client)
                return
            }
            Task {
                let response = await handler(request)
                // Answers can take as long as the hardware does. The client owns the timeout.
                UnixSocket.setTimeout(client, seconds: 30)
                _ = UnixSocket.writeAll(client, response + Data([0x0A]))
                close(client)
            }
        }
    }
}
