#if os(macOS)
  import Foundation

  /// Reads the user's SSH settings for a host through `ssh -G`, which prints them and connects to nothing.
  enum SSHClientConfig {
    static func address(of host: String) async -> SSHClientAddress? {
      await withCheckedContinuation { continuation in
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", host]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
          let data = output.fileHandleForReading.readDataToEndOfFile()
          continuation.resume(returning: process.terminationStatus == 0 ? parse(String(decoding: data, as: UTF8.self)) : nil)
        }
        do {
          try process.run()
          // `Match exec` runs whatever the config says: it doesn't get to hold up a fetch.
          DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if process.isRunning { process.terminate() } }
        } catch {
          continuation.resume(returning: nil)
        }
      }
    }

    /// `key value` lines.
    static func parse(_ text: String) -> SSHClientAddress? {
      var values: [String: String] = [:]
      for line in text.split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 1)
        if parts.count == 2 { values[parts[0].lowercased()] = String(parts[1]) }
      }
      guard let hostname = values["hostname"] else { return nil }
      let isProxied = [values["proxycommand"], values["proxyjump"]].contains { $0 != nil && $0 != "none" }
      return SSHClientAddress(hostname: hostname, port: values["port"].flatMap(Int.init), isProxied: isProxied)
    }
  }
#endif
