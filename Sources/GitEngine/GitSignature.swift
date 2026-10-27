import Foundation

/// Who made a commit and when: git's `Name <email> <seconds> <±hhmm>`.
public struct GitSignature: Sendable, Hashable {
  public var name: String
  public var email: String
  public var date: Date
  /// The offset from UTC written into the commit; the current time zone's when `nil`.
  public var timeZone: TimeZone?

  public init(name: String, email: String, date: Date = .now, timeZone: TimeZone? = nil) {
    self.name = name
    self.email = email
    self.date = date
    self.timeZone = timeZone
  }

  /// `Name <email> 1700000000 +0100`, with `<`, `>` and newlines taken out of the name and email.
  var encoded: String {
    func clean(_ text: String) -> String {
      text.filter { $0 != "<" && $0 != ">" && $0 != "\n" }.trimmingCharacters(in: .whitespaces)
    }
    let seconds = Int(date.timeIntervalSince1970.rounded(.down))
    let offset = (timeZone ?? .current).secondsFromGMT(for: date)
    let minutes = abs(offset) / 60
    let zone = (offset < 0 ? "-" : "+") + String(format: "%02d%02d", minutes / 60, minutes % 60)
    return "\(clean(name)) <\(clean(email))> \(seconds) \(zone)"
  }

  /// Parses `Name <email> 1700000000 +0100`.
  init?(encoded line: Substring) {
    guard let open = line.lastIndex(of: "<"), let close = line[open...].firstIndex(of: ">") else { return nil }
    name = line[..<open].trimmingCharacters(in: .whitespaces)
    email = String(line[line.index(after: open)..<close])
    let rest = line[line.index(after: close)...].split(separator: " ")
    date = Date(timeIntervalSince1970: TimeInterval(rest.first.flatMap { Int($0) } ?? 0))
    if rest.count > 1, let zone = Int(rest[1]) {
      let minutes = (abs(zone) / 100) * 60 + abs(zone) % 100
      timeZone = TimeZone(secondsFromGMT: (zone < 0 ? -1 : 1) * minutes * 60)
    } else {
      timeZone = nil
    }
  }
}
