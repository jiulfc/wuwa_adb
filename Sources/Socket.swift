import Foundation
import Darwin

enum SocketError: Error {
    case eof
    case errno(Int32)
    case closed
}

extension Data {
    /// Appends a fixed-width integer in network byte order (big-endian).
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// A connected POSIX stream socket with exact read/write.
final class PosixSocket {
    let fd: Int32
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
    }

    func readExact(_ count: Int) throws -> Data {
        if count <= 0 { return Data() }
        var buffer = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let n = buffer.withUnsafeMutableBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return -1 }
                return Darwin.read(fd, base + received, count - received)
            }
            if n == 0 { throw SocketError.eof }
            if n < 0 {
                let e = errno
                if e == EINTR { continue }
                throw SocketError.errno(e)
            }
            received += n
        }
        return Data(buffer)
    }

    func readUInt32() throws -> UInt32 {
        try readExact(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    func readUInt64() throws -> UInt64 {
        try readExact(8).reduce(0) { ($0 << 8) | UInt64($1) }
    }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < data.count {
                let n = Darwin.write(fd, base + sent, data.count - sent)
                if n < 0 {
                    let e = errno
                    if e == EINTR { continue }
                    throw SocketError.errno(e)
                }
                if n == 0 { throw SocketError.eof }
                sent += n
            }
        }
    }

    func close() {
        if !closed {
            closed = true
            // Shutdown first to interrupt read/write blocked in other threads
            // (close does not reliably interrupt on macOS), avoiding a crash
            // where a background thread reads wrong data after the fd is reused.
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// A TCP server listening on a random 127.0.0.1 port for the device's reverse connection.
final class TcpServer {
    private let listenFd: Int32
    let port: UInt16
    private var closedFlag = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // Non-blocking, for accept polling + cancellation.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw SocketError.errno(errno)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw SocketError.errno(errno)
        }
        var got = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        self.listenFd = fd
        self.port = UInt16(bigEndian: got.sin_port)
    }

    /// Waits up to timeout seconds and accepts one connection; returns nil on timeout.
    func accept(timeout: TimeInterval) throws -> PosixSocket? {
        let deadline = Date().addingTimeInterval(timeout)
        while !closedFlag {
            let cfd = Darwin.accept(listenFd, nil, nil)
            if cfd >= 0 {
                // On macOS, sockets from accept() inherit the listening socket's O_NONBLOCK;
                // restore blocking mode here so subsequent reads block waiting for data.
                let fl = fcntl(cfd, F_GETFL, 0)
                if fl >= 0 { _ = fcntl(cfd, F_SETFL, fl & ~O_NONBLOCK) }
                return PosixSocket(fd: cfd)
            }
            let e = errno
            if e == EAGAIN || e == EWOULDBLOCK {
                if Date() >= deadline { return nil }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            if e == EINTR { continue }
            throw SocketError.errno(e)
        }
        return nil
    }

    func close() {
        closedFlag = true
        _ = Darwin.shutdown(listenFd, SHUT_RDWR)
        Darwin.close(listenFd)
    }
}

/// Thread-safe boolean flag (for canceling background network loops).
final class AtomicFlag {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
