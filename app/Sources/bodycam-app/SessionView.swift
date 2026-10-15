import AppKit
import SwiftUI

/// One agent run: what to look at, the counts, and the full timeline.
struct SessionView: View {
  @Environment(AppModel.self) private var model
  let id: String

  var body: some View {
    if let session = model.session(id) {
      TimelineView(.periodic(from: .now, by: 1)) { _ in
        SessionContent(session: session, now: model.now)
      }
      .navigationTitle(session.windowTitle)
    } else {
      ContentUnavailableView("This session is gone", systemImage: "questionmark.folder",
        description: Text("bodycam no longer has it. Its report may still be in the reports folder."))
        .frame(minWidth: 500, minHeight: 300)
    }
  }
}

enum TimelineFilter: String, CaseIterable, Identifiable {
  case all = "All", flags = "Flags", commands = "Commands", files = "Files", network = "Network"
  var id: Self { self }

  func matches(_ e: Event) -> Bool {
    switch self {
    case .all: return true
    case .flags: return e.flag
    case .commands: return e.verb == "run" || e.verb == "start"
    case .files: return ["new", "edit", "delete", "read"].contains(e.verb)
    case .network: return e.verb == "net"
    }
  }
}

private struct SessionContent: View {
  @Environment(AppModel.self) private var model
  let session: Session
  let now: Date
  @State private var filter: TimelineFilter = .all
  @State private var selection = Set<Event.ID>()

  var body: some View {
    let findings = session.findings
    VStack(alignment: .leading, spacing: 0) {
      header
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 16)
      counters
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
      if !findings.isEmpty || !session.isActive {
        FindingsList(findings: findings)
          .padding(.horizontal, 24)
          .padding(.bottom, 18)
      }
      Divider()
      timeline
    }
    .frame(minWidth: 640, idealWidth: 760, minHeight: 520, idealHeight: 680)
  }

  private var header: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
          Text(session.agent)
            .font(.system(size: 22, weight: .bold))
          if session.isActive {
            RecBadge(elapsed: session.duration(now: now))
          }
        }
        Label {
          Text(session.place)
            .font(.system(size: 13, design: .monospaced))
            .textSelection(.enabled)
        } icon: {
          Image(systemName: "folder")
        }
        .foregroundStyle(.secondary)
        .font(.system(size: 12))
        Text(timing)
          .font(.system(size: 12))
          .foregroundStyle(.secondary)
        if session.late {
          Text("Recording started after this agent did, so its first moments are missing.")
            .font(.system(size: 11.5))
            .foregroundStyle(.orange)
        }
      }
      Spacer()
      if let report = session.report {
        HStack(spacing: 8) {
          Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: report)])
          } label: {
            Image(systemName: "folder")
          }
          .help("Show the report in Finder")
          .accessibilityLabel("Show the report in Finder")
          Button("Open report") { NSWorkspace.shared.open(URL(fileURLWithPath: report)) }
            .keyboardShortcut("o")
        }
        .controlSize(.large)
      } else if session.isActive {
        Text("The report is saved when it finishes.")
          .font(.system(size: 11.5))
          .foregroundStyle(.tertiary)
          .padding(.top, 6)
      }
    }
  }

  private var timing: String {
    let started = "Started \(Format.when(session.start))"
    if session.isActive { return started }
    return "\(started), ran for \(Format.duration(session.duration(now: now)))"
  }

  private var counters: some View {
    let t = session.totals
    let flags = session.findings.count
    return HStack(spacing: 10) {
      if let n = t.commands { Tile(value: n, label: n == 1 ? "command" : "commands") }
      if let n = t.changed { Tile(value: n, label: n == 1 ? "file changed" : "files changed") }
      if let n = t.reads { Tile(value: n, label: n == 1 ? "file read" : "files read") }
      if let n = t.connections { Tile(value: n, label: n == 1 ? "connection" : "connections") }
      Tile(value: flags, label: flags == 1 ? "thing to look at" : "things to look at", red: flags > 0)
    }
  }

  @ViewBuilder
  private var timeline: some View {
    let rows = session.events.filter(filter.matches)
    VStack(spacing: 0) {
      if !session.events.isEmpty {
        HStack {
          Picker("Show", selection: $filter) {
            ForEach(TimelineFilter.allCases) { f in
              Text(f.rawValue).tag(f)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
          Spacer()
          if session.totals.dropped > 0 {
            Label("macOS dropped \(session.totals.dropped.formatted()) events", systemImage: "exclamationmark.triangle")
              .font(.caption)
              .foregroundStyle(.orange)
              .help("They came faster than bodycam could read them. The report says so too.")
          }
          Text(Format.plural(rows.count, "event"))
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
      }
      if session.events.isEmpty {
        ContentUnavailableView {
          Label(session.fromReport ? "No timeline for this one" : "Nothing yet", systemImage: "list.bullet.rectangle")
        } description: {
          Text(session.fromReport
            ? "The app keeps a timeline for the sessions it recorded itself. The report has everything this one did."
            : "Events show up here as the agent works.")
        }
        .frame(maxHeight: .infinity)
      } else {
        Table(rows, selection: $selection) {
          TableColumn("Time") { e in
            Text(Format.feedTime.string(from: e.time))
              .font(Self.mono)
              .foregroundStyle(.secondary)
          }
          .width(64)
          TableColumn("Who") { e in
            Text(e.who).font(Self.mono).foregroundStyle(.secondary)
          }
          .width(min: 60, ideal: 90, max: 160)
          TableColumn("Did") { e in
            Text(e.verb).font(Self.mono).foregroundStyle(Color.verb(e.verb))
          }
          .width(50)
          TableColumn("What") { e in
            Text(e.what)
              .font(Self.mono)
              .foregroundStyle(e.flag ? Color.flag : .primary)
              .truncationMode(.middle)
              .help(e.what)
          }
          .width(min: 160, ideal: 320)
          TableColumn("Note") { e in
            Text(e.note.isEmpty ? "" : e.label)
              .font(.system(size: 12))
              .foregroundStyle(e.flag ? Color.flag : .orange)
              .help(e.label)
          }
          .width(min: 80, ideal: 170)
        }
        .onCopyCommand {
          rows.filter { selection.contains($0.id) }.map { e in
            NSItemProvider(object: "\(Format.feedTime.string(from: e.time))  \(e.who)  \(e.verb)  \(e.what)\(e.note.isEmpty ? "" : "  ! " + e.label)" as NSString)
          }
        }
      }
    }
  }

  static let mono = Font.system(size: 11.5, design: .monospaced)
}

private struct Tile: View {
  let value: Int
  let label: String
  var red = false

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value.formatted())
        .font(.system(size: 20, weight: .semibold).monospacedDigit())
        .foregroundStyle(red ? Color.flag : .primary)
      Text(label)
        .font(.system(size: 11))
        .foregroundStyle(red ? Color.flag : .secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.85)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .fill(red ? Color.rec.opacity(0.09) : Color.primary.opacity(0.045))
    )
    .accessibilityElement(children: .combine)
  }
}

private struct FindingsList: View {
  let findings: [Finding]

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 6) {
        Text("Things to look at")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(findings.isEmpty ? Color.primary : Color.flag)
        if !findings.isEmpty {
          Text("\(findings.count)")
            .font(.system(size: 11, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.rec))
        }
      }
      if findings.isEmpty {
        Label("Nothing stood out.", systemImage: "checkmark.circle")
          .font(.system(size: 12.5))
          .foregroundStyle(.green)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(findings.enumerated()), id: \.offset) { i, f in
              if i > 0 { Divider().opacity(0.5) }
              FindingRow(finding: f)
            }
          }
        }
        .frame(maxHeight: findings.count > 6 ? 200 : nil)
        .fixedSize(horizontal: false, vertical: findings.count <= 6)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.rec.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.rec.opacity(0.18)))
      }
    }
  }
}

private struct FindingRow: View {
  let finding: Finding

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 10) {
      Circle().fill(Color.rec).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
      Text(finding.label)
        .font(.system(size: 12.5, weight: .medium))
        .foregroundStyle(Color.flag)
        .frame(width: 200, alignment: .leading)
        .lineLimit(1)
      Text(finding.what)
        .font(.system(size: 11.5, design: .monospaced))
        .foregroundStyle(.primary)
        .lineLimit(1)
        .truncationMode(.middle)
        .help(finding.what)
        .frame(maxWidth: .infinity, alignment: .leading)
      if !finding.detail.isEmpty {
        Text(finding.detail)
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
    .padding(.vertical, 6)
    .textSelection(.enabled)
    .accessibilityElement(children: .combine)
  }
}
