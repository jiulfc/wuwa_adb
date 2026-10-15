import Foundation
import Darwin

enum SocketError: Error {
    case eof
    case errno(Int32)
    case closed
}

extension Data {
    /// 以网络字节序（大端）追加一个定长整数。
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var v = value.bigEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// 一个已连接的 POSIX 流套接字，提供精确读取/写入。
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
            // 先 shutdown 打断其它线程阻塞中的 read/write（macOS 上 close 不会可靠地打断），
            // 避免 fd 被复用后后台线程读到错误数据导致崩溃。
            _ = Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
    }
}

/// 监听 127.0.0.1 随机端口、接受设备反向连接进来的 TCP 服务器。
final class TcpServer {
    private let listenFd: Int32
    let port: UInt16
    private var closedFlag = false

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.errno(errno) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        // 非阻塞，便于 accept 轮询 + 取消。
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

    /// 在 timeout 秒内等待并接受一个连接；超时返回 nil。
    func accept(timeout: TimeInterval) throws -> PosixSocket? {
        let deadline = Date().addingTimeInterval(timeout)
        while !closedFlag {
            let cfd = Darwin.accept(listenFd, nil, nil)
            if cfd >= 0 {
                // macOS 上 accept() 出的 socket 会继承监听 socket 的 O_NONBLOCK，
                // 这里恢复为阻塞模式，保证后续 read 阻塞等待数据。
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

/// 跨线程安全的布尔开关（用于取消后台网络循环）。
final class AtomicFlag {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
