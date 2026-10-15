import AppKit
import Observation
import SwiftUI

/// One line of the engine's events file. app/ENGINE.md describes them.
struct Line: Decodable {
  var type: String
  var time: Date
  var state, error, hint, version: String?
  var pid: Int?
  var session, agent, project: String?
  var late: Bool?
  var who, verb, what, note: String?
  var flag: Bool?
  var seconds: Int?
  var findings: [Finding]?
  var commands, changed, changed_outside, deleted, reads, reads_outside, connections, dropped: Int?
  var report: String?

  static let decoder: JSONDecoder = {
    let d = JSONDecoder()
    let plain = ISO8601DateFormatter()
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    d.dateDecodingStrategy = .custom { decoder in
      let s = try decoder.singleValueContainer().decode(String.self)
      if let date = plain.date(from: s) ?? fractional.date(from: s) { return date }
      throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad time \(s)"))
    }
    return d
  }()
}

struct Finding: Decodable, Hashable {
  var label: String
  var what: String
  var who: [String]?
  var count: Int?

  var detail: String {
    var parts: [String] = []
    if let count, count > 1 { parts.append("×\(count)") }
    if let who, !who.isEmpty { parts.append("by " + who.joined(separator: ", ")) }
    return parts.joined(separator: ", ")
  }
}

struct Event: Identifiable, Hashable {
  let id: Int
  let time: Date
  let who, verb, what, note: String
  let flag: Bool

  /// The finding as the report words it: "read an .env file", "used sudo".
  var label: String { verb == "read" && !note.hasPrefix("read") ? "read \(note)" : note }
}

struct Totals {
  var commands, changed, deleted, reads, connections: Int?
  var dropped = 0
}

struct Session: Identifiable {
  let id: String
  var agent: String
  var project: String
  var pid: Int
  var start: Date
  var end: Date?
  var late = false
  var events: [Event] = []
  var flagged: [Event] = []
  var endTotals: Totals?
  var endFindings: [Finding]?
  var report: String?
  var lastActivity: Date
  var fromReport = false

  var isActive: Bool { end == nil }

  var findings: [Finding] {
    if let endFindings { return endFindings }
    var out: [Finding] = []
    var index: [String: Int] = [:]
    for e in flagged {
      let key = e.label + "\u{0}" + e.what
      if let i = index[key] {
        out[i].count = (out[i].count ?? 1) + 1
        if !(out[i].who ?? []).contains(e.who) { out[i].who?.append(e.who) }
      } else {
        index[key] = out.count
        out.append(Finding(label: e.label, what: e.what, who: [e.who], count: 1))
      }
    }
    return out
  }

  /// Exact numbers once the engine sends the end line; while recording, counted from the feed.
  var totals: Totals {
    if let endTotals { return endTotals }
    func distinct(_ verbs: Set<String>) -> Int { Set(events.filter { verbs.contains($0.verb) }.map(\.what)).count }
    return Totals(
      commands: events.filter { $0.verb == "run" }.count,
      changed: distinct(["new", "edit"]),
      deleted: distinct(["delete"]),
      reads: nil,
      connections: distinct(["net"]))
  }

  func duration(now: Date) -> TimeInterval { max(0, (end ?? now).timeIntervalSince(start)) }
}

enum EngineState: Equatable {
  case off, starting, watching, stopping
  case failed(message: String, hint: String?)

  var isOn: Bool { self == .starting || self == .watching || self == .stopping }
}

struct Paths {
  let logs: URL
  let events: URL
  var runFile: URL { events.deletingLastPathComponent().appendingPathComponent(".recording") }
  var engineLog: URL { events.deletingLastPathComponent().appendingPathComponent("engine.log") }
  var engine: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/bodycam") }

  init(events override: String? = nil) {
    logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/bodycam")
    events = override.map { URL(fileURLWithPath: $0) } ?? logs.appendingPathComponent("events.jsonl")
  }
}

@MainActor @Observable
final class AppModel {
  static let shared = AppModel(events: argument("--events"))

  let paths: Paths
  var engine: EngineState = .off {
    didSet { if oldValue.isOn != engine.isOn, timer != nil { schedulePolling() } }
  }
  private(set) var sessions: [String: Session] = [:]
  private(set) var reportSessions: [Session] = []
  var unseenFlags = 0
  var popoverOpen = false {
    didSet { if popoverOpen { unseenFlags = 0 } }
  }
  /// Fixed clock for snapshots.
  var snapshotNow: Date?
  var demoRunning = false

  @ObservationIgnored var openWindowAction: OpenWindowAction?
  @ObservationIgnored var pendingDemo = false
  @ObservationIgnored var watchdog: DispatchWorkItem?
  @ObservationIgnored var engineLogStart: UInt64 = 0
  @ObservationIgnored var enginePID = 0
  @ObservationIgnored private var tail = Tail()
  @ObservationIgnored private var timer: Timer?
  @ObservationIgnored private var nextID = 0

  init(events: String?) {
    paths = Paths(events: events)
  }

  var now: Date { snapshotNow ?? Date() }

  var active: [Session] { sessions.values.filter(\.isActive).sorted { $0.start < $1.start } }

  var recent: [Session] {
    let ended = sessions.values.filter { !$0.isActive }
    let known = Set(ended.compactMap(\.report))
    return (ended + reportSessions.filter { !known.contains($0.report ?? "") })
      .sorted { ($0.end ?? $0.start) > ($1.end ?? $1.start) }
  }

  var isRecording: Bool { engine == .watching && !active.isEmpty }

  func session(_ id: String) -> Session? {
    sessions[id] ?? reportSessions.first { $0.id == id }
  }

  // MARK: Reading the events file

  /// Reads what is already in the events file and the saved reports, then follows the file.
  func launch() {
    try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)
    load(paths.events.path, includeReports: true)
    if !engine.isOn { try? FileManager.default.removeItem(at: paths.runFile) }
    schedulePolling()
  }

  func load(_ path: String, includeReports: Bool, assumeRunning: Bool = false) {
    tail = Tail(path: path)
    var lastStatus: Line?
    for line in tail.read(initial: true) {
      if line.type == "status" { lastStatus = line }
      apply(line, live: false)
    }
    if assumeRunning {
      engine = .watching
    } else if let s = lastStatus, s.state == "recording", let pid = s.pid, processAlive(pid) {
      enginePID = pid
      engine = .watching
    } else {
      closeOpenSessions(at: nil)
    }
    if includeReports { reportSessions = Reports.load(from: paths.logs) }
  }

  private func schedulePolling() {
    timer?.invalidate()
    let interval = engine.isOn || !active.isEmpty ? 0.5 : 2
    timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.poll() }
    }
    timer?.tolerance = interval / 4
  }

  private func poll() {
    for line in tail.read(initial: false) { apply(line, live: true) }
    // An engine that was killed never writes "stopped".
    if engine == .watching, enginePID > 0, !processAlive(enginePID) {
      closeOpenSessions(at: nil)
      engine = .off
    }
  }

  func pollNow() { poll() }

  func apply(_ line: Line, live: Bool) {
    switch line.type {
    case "status":
      switch line.state {
      case "recording":
        closeOpenSessions(at: nil, before: line.time)
        if live {
          watchdog?.cancel()
          enginePID = line.pid ?? 0
          engine = .watching
          Notifier.shared.requestAuthorization()
          if pendingDemo {
            pendingDemo = false
            runDemo()
          }
        }
      case "stopped":
        closeOpenSessions(at: line.time)
        if live {
          watchdog?.cancel()
          engine = .off
          try? FileManager.default.removeItem(at: paths.runFile)
        }
      case "error":
        if live {
          watchdog?.cancel()
          pendingDemo = false
          engine = .failed(message: line.error ?? "The recorder stopped.", hint: line.hint.flatMap { $0.isEmpty ? nil : $0 })
          try? FileManager.default.removeItem(at: paths.runFile)
        }
      default: break
      }
    case "start":
      guard let id = line.session else { return }
      if sessions[id] == nil {
        sessions[id] = Session(
          id: id, agent: line.agent ?? "agent", project: line.project ?? "", pid: line.pid ?? 0,
          start: line.time, late: line.late ?? false, lastActivity: line.time)
      }
    case "event":
      guard let id = line.session else { return }
      if sessions[id] == nil {
        sessions[id] = Session(id: id, agent: line.who ?? "agent", project: "", pid: 0, start: line.time, lastActivity: line.time)
      }
      nextID += 1
      let e = Event(
        id: nextID, time: line.time, who: line.who ?? "", verb: line.verb ?? "", what: line.what ?? "",
        note: line.note ?? "", flag: line.flag ?? false)
      sessions[id]?.events.append(e)
      sessions[id]?.lastActivity = line.time
      // ponytail: keeps the newest 5000 feed lines per session; flags are kept apart so none are lost.
      if (sessions[id]?.events.count ?? 0) > 5000 { sessions[id]?.events.removeFirst(1000) }
      if e.flag {
        sessions[id]?.flagged.append(e)
        if live, let s = sessions[id] {
          if !popoverOpen { unseenFlags += 1 }
          Notifier.shared.flagged(e, in: s)
        }
      }
    case "end":
      guard let id = line.session else { return }
      var s = sessions[id] ?? Session(
        id: id, agent: line.agent ?? "agent", project: line.project ?? "", pid: line.pid ?? 0,
        start: line.time.addingTimeInterval(-Double(line.seconds ?? 0)), lastActivity: line.time)
      s.end = line.time
      s.endFindings = line.findings ?? []
      s.endTotals = Totals(
        commands: line.commands, changed: (line.changed ?? 0) + (line.changed_outside ?? 0),
        deleted: line.deleted, reads: (line.reads ?? 0) + (line.reads_outside ?? 0),
        connections: line.connections, dropped: line.dropped ?? 0)
      s.report = line.report.flatMap { $0.isEmpty ? nil : $0 }
      sessions[id] = s
    default: break
    }
  }

  /// A session with no end line is over once the engine stops or a new engine starts.
  func closeOpenSessions(at time: Date?, before: Date? = nil) {
    for (id, s) in sessions where s.isActive {
      if let before, s.start >= before { continue }
      sessions[id]?.end = time ?? s.lastActivity
    }
  }

  // MARK: Windows

  func openSession(_ id: String) {
    NSApp.activate(ignoringOtherApps: true)
    openWindowAction?(id: "session", value: id)
  }

  func openWelcome() {
    NSApp.activate(ignoringOtherApps: true)
    openWindowAction?(id: "welcome")
  }

  func openReportsFolder() {
    NSWorkspace.shared.open(paths.logs)
  }
}

func processAlive(_ pid: Int) -> Bool {
  kill(pid_t(pid), 0) == 0 || errno == EPERM
}

func argument(_ name: String) -> String? {
  let args = CommandLine.arguments
  guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
  return args[i + 1]
}

/// Follows an append-only file and hands back whole lines.
struct Tail {
  var path = ""
  private var offset: UInt64 = 0
  private var inode: UInt64 = 0
  private var partial = Data()

  init(path: String = "") { self.path = path }

  mutating func read(initial: Bool) -> [Line] {
    guard !path.isEmpty,
      let attrs = try? FileManager.default.attributesOfItem(atPath: path),
      let size = (attrs[.size] as? NSNumber)?.uint64Value
    else { return [] }
    let node = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
    if node != inode || size < offset {
      inode = node
      offset = 0
      partial = Data()
    }
    // ponytail: at launch only the last 8 MB is read; older sessions still come from the reports.
    var skipFirst = false
    if initial && size > 8 << 20 {
      offset = size - (8 << 20)
      skipFirst = true
    }
    guard size > offset, let handle = FileHandle(forReadingAtPath: path) else { return [] }
    defer { try? handle.close() }
    try? handle.seek(toOffset: offset)
    let data = handle.readDataToEndOfFile()
    offset += UInt64(data.count)
    partial.append(data)
    var lines: [Line] = []
    while let nl = partial.firstIndex(of: 0x0A) {
      let chunk = partial[partial.startIndex..<nl]
      partial = Data(partial[partial.index(after: nl)...])
      if skipFirst {
        skipFirst = false
        continue
      }
      if let line = try? Line.decoder.decode(Line.self, from: chunk) { lines.append(line) }
    }
    return lines
  }
}

/// Sessions from the Markdown reports in ~/Library/Logs/bodycam, for history the events file no longer has.
enum Reports {
  static func load(from dir: URL, limit: Int = 40) -> [Session] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasSuffix(".md") }.sorted(by: >).prefix(limit).compactMap {
      parse(dir.appendingPathComponent($0))
    }
  }

  static let stamp: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd-HHmmss"
    return f
  }()

  /// Reads a report named like 2026-10-16-023507-claude-42826.md.
  static func parse(_ url: URL) -> Session? {
    let name = url.deletingPathExtension().lastPathComponent
    guard name.count > 18, let start = stamp.date(from: String(name.prefix(17))),
      let text = try? String(contentsOf: url, encoding: .utf8)
    else { return nil }
    var rest = String(name.dropFirst(18))
    var pid = 0
    if let dash = rest.lastIndex(of: "-"), let n = Int(rest[rest.index(after: dash)...]) {
      pid = n
      rest = String(rest[..<dash])
    }
    var project = ""
    var seconds = 0.0
    var findings: [Finding] = []
    var commands: Int?
    var changed: Int?
    var section = ""
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("## ") {
        section = String(line.dropFirst(3))
        if section.hasPrefix("Commands ("), let n = Int(section.dropFirst(10).prefix { $0.isNumber }) { commands = n }
        if section.hasPrefix("Files changed"), let open = section.lastIndex(of: "(") {
          changed = Int(section[section.index(after: open)...].prefix { $0.isNumber })
        }
        continue
      }
      if line.hasPrefix("- Project: ") { project = line.dropFirst(11).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
      if line.hasPrefix("- Ran: "), let open = line.lastIndex(of: "("), line.hasSuffix(")") {
        seconds = goDuration(String(line[line.index(after: open)..<line.index(before: line.endIndex)]))
      }
      if section == "Things to look at", line.hasPrefix("- ") { findings.append(finding(String(line.dropFirst(2)))) }
    }
    return Session(
      id: "report:" + url.path, agent: rest, project: project, pid: pid, start: start,
      end: start.addingTimeInterval(seconds), endTotals: Totals(commands: commands, changed: changed),
      endFindings: findings, report: url.path, lastActivity: start, fromReport: true)
  }

  /// "read an .env file: `.env` (×6, by node, claude, bat)"
  static func finding(_ s: String) -> Finding {
    guard let colon = s.range(of: ": `") else { return Finding(label: s, what: "") }
    let label = String(s[..<colon.lowerBound])
    let afterTick = s[colon.upperBound...]
    guard let close = afterTick.firstIndex(of: "`") else { return Finding(label: label, what: String(afterTick)) }
    let what = String(afterTick[..<close])
    var extra = afterTick[afterTick.index(after: close)...].trimmingCharacters(in: .whitespaces)
    extra = extra.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    var count: Int?
    var who: [String]?
    if extra.hasPrefix("×") { count = Int(extra.dropFirst().prefix { $0.isNumber }) }
    if let by = extra.range(of: "by ") { who = extra[by.upperBound...].components(separatedBy: ", ") }
    return Finding(label: label, what: what, who: who, count: count)
  }

  /// Go's time.Duration strings: "4s", "1m23s", "1h2m3s", "850ms".
  static func goDuration(_ s: String) -> Double {
    var total = 0.0
    var number = ""
    var unit = ""
    func flush() {
      guard let n = Double(number) else { return }
      switch unit {
      case "h": total += n * 3600
      case "m": total += n * 60
      case "s": total += n
      case "ms": total += n / 1000
      default: break
      }
      number = ""
      unit = ""
    }
    for c in s {
      if c.isNumber || c == "." {
        if !unit.isEmpty { flush() }
        number.append(c)
      } else {
        unit.append(c)
      }
    }
    flush()
    return total
  }
}
