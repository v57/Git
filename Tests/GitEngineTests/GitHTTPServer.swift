import Foundation

/// A tiny HTTP server on 127.0.0.1 that serves the bare repositories under `root` through `git http-backend` (CGI),
/// so clone, fetch and push run against real git.
final class GitHTTPServer: @unchecked Sendable {
  let root: URL
  private(set) var port: UInt16 = 0
  private let listener: Int32
  /// Paths containing `private` need this `Authorization` header.
  var requiredAuthorization: String?
  /// Drops the `Git-Protocol` header, so git answers in protocol v0.
  var allowsVersion2 = true
  private let lock = NSLock()
  private var running = true

  var baseURL: String { "http://127.0.0.1:\(port)" }

  init(root: URL) throws {
    self.root = root
    #if canImport(Darwin)
      listener = socket(AF_INET, SOCK_STREAM, 0)
    #else
      listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    var yes: Int32 = 1
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = 0
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(listener, 16) == 0 else {
      throw GitFailure(description: "Couldn't start the test server.")
    }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
    }
    port = UInt16(bigEndian: address.sin_port)
    let listener = listener
    Thread.detachNewThread { [weak self] in
      while true {
        let connection = accept(listener, nil, nil)
        guard connection >= 0, let self, self.isRunning else { return }
        Thread.detachNewThread { self.handle(connection) }
      }
    }
  }

  private var isRunning: Bool { lock.withLock { running } }

  func stop() {
    lock.withLock { running = false }
    shutdown(listener, Int32(SHUT_RDWR))
    close(listener)
  }

  deinit { stop() }

  private func readRequest(_ connection: Int32) -> (head: String, body: Data)? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
      let count = read(connection, &chunk, chunk.count)
      guard count > 0 else { return nil }
      buffer.append(contentsOf: chunk[0..<count])
      headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
    }
    let head = String(decoding: buffer[..<headerEnd!.lowerBound], as: UTF8.self)
    var body = Data(buffer[headerEnd!.upperBound...])
    let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
      .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
    while body.count < length {
      let count = read(connection, &chunk, chunk.count)
      guard count > 0 else { return nil }
      body.append(contentsOf: chunk[0..<count])
    }
    return (head, body)
  }

  private func handle(_ connection: Int32) {
    defer { close(connection) }
    guard let (head, body) = readRequest(connection) else { return }
    let lines = head.split(separator: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    guard requestLine.count >= 2 else { return }
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
      let parts = line.split(separator: ":", maxSplits: 1)
      if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
    }
    let target = String(requestLine[1])
    let path = String(target.split(separator: "?", maxSplits: 1)[0])
    let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""
    if path.contains("private"), let required = requiredAuthorization, headers["authorization"] != required {
      respond(
        connection, status: "401 Unauthorized", headers: ["WWW-Authenticate": "Basic realm=\"test\""], body: Data())
      return
    }
    // A path the redirect test asks for.
    if path.hasPrefix("/moved/") {
      let location = target.replacingOccurrences(of: "/moved/", with: "/")
      respond(connection, status: "301 Moved Permanently", headers: ["Location": location], body: Data())
      return
    }
    var environment = ProcessInfo.processInfo.environment.merging(gitEnvironment) { $1 }
    environment["GIT_PROJECT_ROOT"] = root.path
    environment["GIT_HTTP_EXPORT_ALL"] = "1"
    environment["PATH_INFO"] = path
    environment["QUERY_STRING"] = query
    environment["REQUEST_METHOD"] = String(requestLine[0])
    environment["CONTENT_TYPE"] = headers["content-type"] ?? ""
    environment["CONTENT_LENGTH"] = String(body.count)
    environment["REMOTE_USER"] = "tester"
    environment["REMOTE_ADDR"] = "127.0.0.1"
    if allowsVersion2, let protocolHeader = headers["git-protocol"] {
      environment["HTTP_GIT_PROTOCOL"] = protocolHeader
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["http-backend"]
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return }
    DispatchQueue.global().async {
      input.fileHandleForWriting.write(body)
      try? input.fileHandleForWriting.close()
    }
    let result = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    // CGI output: headers, a blank line, the body.
    let separator = result.range(of: Data("\r\n\r\n".utf8)) ?? result.range(of: Data("\n\n".utf8))
    guard let separator else {
      respond(connection, status: "500 Internal Server Error", headers: [:], body: result)
      return
    }
    var status = "200 OK"
    var responseHeaders: [String: String] = [:]
    for line in String(decoding: result[..<separator.lowerBound], as: UTF8.self).split(whereSeparator: \.isNewline) {
      let parts = line.split(separator: ":", maxSplits: 1)
      guard parts.count == 2 else { continue }
      let value = parts[1].trimmingCharacters(in: .whitespaces)
      if parts[0].lowercased() == "status" { status = value } else { responseHeaders[String(parts[0])] = value }
    }
    respond(connection, status: status, headers: responseHeaders, body: Data(result[separator.upperBound...]))
  }

  private func respond(_ connection: Int32, status: String, headers: [String: String], body: Data) {
    var text = "HTTP/1.1 \(status)\r\n"
    for (name, value) in headers { text += "\(name): \(value)\r\n" }
    text += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    var data = Data(text.utf8)
    data.append(body)
    data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = write(connection, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count <= 0 { return }
        offset += count
      }
    }
  }
}
