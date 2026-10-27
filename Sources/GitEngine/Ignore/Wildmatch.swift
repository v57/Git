import Foundation

/// git's `wildmatch`: `*`, `?`, `[...]` classes and `**` across folders, with `*` stopping at `/` when matching a
/// path.
enum Wildmatch {
  private enum Result { case match, noMatch, abortAll, abortToStarStar }

  /// Whether `text` matches `pattern`. With `pathname`, `*` and `?` don't match `/` and `**` spans folders.
  static func matches(_ pattern: [UInt8], _ text: [UInt8], pathname: Bool) -> Bool {
    match(pattern, 0, text, 0, pathname) == .match
  }

  private static let slash = UInt8(ascii: "/")

  private static func match(_ p: [UInt8], _ pStart: Int, _ t: [UInt8], _ tStart: Int, _ pathname: Bool) -> Result {
    var pi = pStart
    var ti = tStart
    while pi < p.count {
      var pc = p[pi]
      if ti >= t.count && pc != UInt8(ascii: "*") { return .abortAll }
      switch pc {
      case UInt8(ascii: "\\"):
        pi += 1
        guard pi < p.count else { return .noMatch }
        pc = p[pi]
        if t[ti] != pc { return .noMatch }
      case UInt8(ascii: "?"):
        if pathname && t[ti] == slash { return .noMatch }
      case UInt8(ascii: "*"):
        var matchSlash: Bool
        pi += 1
        if pi < p.count && p[pi] == UInt8(ascii: "*") {
          let before = pi - 2
          while pi < p.count && p[pi] == UInt8(ascii: "*") { pi += 1 }
          if !pathname {
            matchSlash = true
          } else if (before < 0 || p[before] == slash)
            && (pi == p.count || p[pi] == slash
              || (p[pi] == UInt8(ascii: "\\") && pi + 1 < p.count && p[pi + 1] == slash))
          {
            // `**/` also matches no folders at all.
            if pi < p.count, p[pi] == slash, match(p, pi + 1, t, ti, pathname) == .match { return .match }
            matchSlash = true
          } else {
            matchSlash = false
          }
        } else {
          matchSlash = !pathname
        }
        if pi == p.count {
          // A trailing `*` matches the rest unless that crosses a folder.
          if !matchSlash && t[ti...].contains(slash) { return .abortToStarStar }
          return .match
        }
        if !matchSlash && p[pi] == slash {
          guard let next = t[ti...].firstIndex(of: slash) else { return .abortAll }
          ti = next
          continue
        }
        while true {
          if ti >= t.count { return .abortAll }
          let result = match(p, pi, t, ti, pathname)
          if result != .noMatch {
            if !matchSlash || result != .abortToStarStar { return result }
          } else if !matchSlash && t[ti] == slash {
            return .abortToStarStar
          }
          ti += 1
        }
      case UInt8(ascii: "["):
        guard let (matched, end) = matchClass(p, pi, t[ti]) else {
          // An unterminated class is a literal `[`.
          if t[ti] != pc { return .noMatch }
          break
        }
        if !matched || (pathname && t[ti] == slash) { return .noMatch }
        pi = end
      default:
        if t[ti] != pc { return .noMatch }
      }
      pi += 1
      ti += 1
    }
    return ti == t.count ? .match : .noMatch
  }

  /// Matches one character against the class starting at `start` (`[`). Returns whether it matched and the index
  /// of the closing `]`, or `nil` when the class isn't closed.
  private static func matchClass(_ p: [UInt8], _ start: Int, _ character: UInt8) -> (Bool, Int)? {
    var pi = start + 1
    guard pi < p.count else { return nil }
    var negated = false
    if p[pi] == UInt8(ascii: "!") || p[pi] == UInt8(ascii: "^") {
      negated = true
      pi += 1
    }
    var matched = false
    var first = true
    while pi < p.count {
      var pc = p[pi]
      if pc == UInt8(ascii: "]") && !first { return (matched != negated, pi) }
      first = false
      if pc == UInt8(ascii: "\\") {
        pi += 1
        guard pi < p.count else { return nil }
        pc = p[pi]
      } else if pc == UInt8(ascii: "["), pi + 1 < p.count, p[pi + 1] == UInt8(ascii: ":"),
        let close = findClassEnd(p, pi + 2)
      {
        let name = String(decoding: p[(pi + 2)..<close], as: UTF8.self)
        if matchesNamedClass(name, character) { matched = true }
        pi = close + 2
        continue
      }
      if pi + 2 < p.count, p[pi + 1] == UInt8(ascii: "-"), p[pi + 2] != UInt8(ascii: "]") {
        var upper = p[pi + 2]
        var skip = 2
        if upper == UInt8(ascii: "\\"), pi + 3 < p.count {
          upper = p[pi + 3]
          skip = 3
        }
        if character >= pc && character <= upper { matched = true }
        pi += skip + 1
        continue
      }
      if character == pc { matched = true }
      pi += 1
    }
    return nil
  }

  private static func findClassEnd(_ p: [UInt8], _ start: Int) -> Int? {
    var index = start
    while index + 1 < p.count {
      if p[index] == UInt8(ascii: ":") && p[index + 1] == UInt8(ascii: "]") { return index }
      if p[index] == UInt8(ascii: "]") { return nil }
      index += 1
    }
    return nil
  }

  private static func matchesNamedClass(_ name: String, _ byte: UInt8) -> Bool {
    let character = Character(Unicode.Scalar(byte))
    switch name {
    case "alnum": return character.isASCII && (character.isLetter || character.isNumber)
    case "alpha": return character.isASCII && character.isLetter
    case "digit": return character.isASCII && character.isNumber
    case "lower": return character.isASCII && character.isLowercase
    case "upper": return character.isASCII && character.isUppercase
    case "space": return byte == 0x20 || (0x09...0x0D).contains(byte)
    case "blank": return byte == 0x20 || byte == 0x09
    case "punct": return character.isASCII && character.isPunctuation || character.isSymbol && character.isASCII
    case "xdigit": return character.isHexDigit
    case "print": return (0x20...0x7E).contains(byte)
    case "graph": return (0x21...0x7E).contains(byte)
    case "cntrl": return byte < 0x20 || byte == 0x7F
    default: return false
    }
  }
}
