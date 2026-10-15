import AppKit
import SwiftUI

/// The window that opens from the menu bar.
struct PopoverView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openSettings) private var openSettings
  static let width: CGFloat = 380

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { _ in
      content(now: model.now)
    }
    .frame(width: Self.width)
    .onAppear { model.popoverOpen = true }
    .onDisappear { model.popoverOpen = false }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
      if isPopover(note.object) { model.popoverOpen = true }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
      if isPopover(note.object) { model.popoverOpen = false }
    }
  }

  private func isPopover(_ object: Any?) -> Bool {
    guard let window = object as? NSWindow else { return false }
    return String(describing: type(of: window)).contains("MenuBarExtra")
  }

  @ViewBuilder
  private func content(now: Date) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      header(now: now)
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 14)
      if case .failed(let message, let hint) = model.engine {
        FailureBox(message: message, hint: hint)
          .padding(.horizontal, 16)
          .padding(.bottom, 14)
      }
      Divider().padding(.horizontal, 16)
      middle(now: now)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
      Divider().padding(.horizontal, 16)
      footer
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
  }

  // MARK: Header

  private func header(now: Date) -> some View {
    let active = model.active
    return VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .center, spacing: 11) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .frame(width: 34, height: 34)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 2) {
          Text(title(active))
            .font(.system(size: 14, weight: .semibold))
            .lineLimit(1)
          Text(subtitle(active))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 8)
        if model.engine == .watching, let first = active.first {
          RecBadge(elapsed: first.duration(now: now))
        }
      }
      .accessibilityElement(children: .combine)
      primaryButton
    }
  }

  private func title(_ active: [Session]) -> String {
    switch model.engine {
    case .off: return "bodycam is off"
    case .starting: return "Starting"
    case .stopping: return "Stopping"
    case .failed: return "bodycam couldn't record"
    case .watching:
      if active.count == 1 { return "Recording \(active[0].agent)" }
      if active.count > 1 { return "Recording \(active.count) agents" }
      return "Watching for agents"
    }
  }

  private func subtitle(_ active: [Session]) -> String {
    switch model.engine {
    case .off: return "Start recording, then use your agents as usual."
    case .starting: return "Enter your Mac password in the dialog to start."
    case .stopping: return "Finishing the reports."
    case .failed: return "Nothing is being recorded right now."
    case .watching:
      if active.count == 1 { return active[0].place }
      if active.count > 1 { return active.map(\.agent).joined(separator: ", ") }
      return "Start Claude Code, Codex or any agent and it shows up here."
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    switch model.engine {
    case .watching, .stopping:
      Button { model.stop() } label: {
        Label("Stop recording", systemImage: "stop.fill")
          .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .disabled(model.engine == .stopping)
    case .off, .failed, .starting:
      Button { model.start() } label: {
        HStack(spacing: 7) {
          if model.engine == .starting {
            ProgressView().controlSize(.small).tint(.white)
          } else {
            Image(systemName: "record.circle")
          }
          Text(model.engine == .starting ? "Waiting for your password" : "Start recording")
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(RecordButtonStyle())
      .disabled(model.engine == .starting)
      .keyboardShortcut(.defaultAction)
    }
  }

  // MARK: Sessions

  @ViewBuilder
  private func middle(now: Date) -> some View {
    let active = model.active
    let recent = Array(model.recent.prefix(active.isEmpty ? 5 : 3))
    VStack(alignment: .leading, spacing: 14) {
      if !active.isEmpty {
        VStack(alignment: .leading, spacing: 8) {
          SectionTitle(title: "Recording now")
          ForEach(active.prefix(2)) { session in
            ActiveCard(session: session, now: now, lines: active.count > 1 ? 2 : 3)
          }
          if active.count > 2 {
            Text("and \(Format.plural(active.count - 2, "more agent"))")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
      } else {
        DemoPrompt(watching: model.engine == .watching)
      }
      if !recent.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          SectionTitle(
            title: "Recent",
            trailing: AnyView(
              Button("Show all") { model.openReportsFolder() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Open the reports folder")))
          VStack(spacing: 0) {
            ForEach(recent) { session in
              RecentRow(session: session)
            }
          }
          .padding(.horizontal, -8)
        }
      }
    }
  }

  // MARK: Footer

  private var footer: some View {
    HStack(spacing: 2) {
      FooterButton(title: "Settings", symbol: "gearshape") {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
      }
      .keyboardShortcut(",")
      FooterButton(title: "Reports", symbol: "folder") { model.openReportsFolder() }
        .help("Open ~/Library/Logs/bodycam")
      Spacer()
      FooterButton(title: "Quit", symbol: "power") { NSApp.terminate(nil) }
        .keyboardShortcut("q")
        .help(model.engine.isOn ? "Quitting stops recording" : "Quit bodycam")
    }
  }
}

private struct FooterButton: View {
  let title: String
  let symbol: String
  let action: () -> Void
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      Label(title, systemImage: symbol)
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    .onHover { hovering = $0 }
  }
}

/// Shown when no agent is running: what happens next, and the demo.
private struct DemoPrompt: View {
  @Environment(AppModel.self) private var model
  let watching: Bool

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(watching ? "No agent is running yet" : "Not sure what you'll see?")
          .font(.system(size: 12, weight: .medium))
        Text("The demo runs a harmless pretend agent that bodycam flags.")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 4)
      Button(model.demoRunning ? "Running" : "Try the demo") { model.tryDemo() }
        .buttonStyle(HiVisButtonStyle())
        .disabled(model.demoRunning || model.engine == .starting || model.engine == .stopping)
        .help("Starts recording if needed, then runs the pretend agent")
    }
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
  }
}

/// An agent being recorded: where, for how long, the counts, and the last few feed lines.
private struct ActiveCard: View {
  @Environment(AppModel.self) private var model
  let session: Session
  let now: Date
  let lines: Int

  var body: some View {
    let totals = session.totals
    let flags = session.findings.count
    HoverRow(action: { model.openSession(session.id) }) {
      HStack(alignment: .top, spacing: 10) {
        RoundedRectangle(cornerRadius: 1.5)
          .fill(Color.hiVis)
          .frame(width: 3)
        VStack(alignment: .leading, spacing: 7) {
          HStack(alignment: .firstTextBaseline) {
            Text(session.agent).font(.system(size: 13, weight: .semibold))
            Text(session.place)
              .font(.system(size: 11.5, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
            Spacer(minLength: 6)
            Text(Format.clock(session.duration(now: now)))
              .font(.system(size: 12).monospacedDigit())
              .foregroundStyle(.secondary)
          }
          HStack(spacing: 12) {
            Stat(value: totals.commands ?? 0, label: "commands")
            Stat(value: totals.changed ?? 0, label: "changed")
            Stat(value: flags, label: flags == 1 ? "flag" : "flags", red: flags > 0)
          }
          let findings = session.findings
          if !findings.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              ForEach(Array(findings.suffix(3).enumerated()), id: \.offset) { _, f in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                  Text(f.label)
                    .font(.system(size: 11.5, weight: .medium))
                    .fixedSize()
                  Text(f.what)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
                .foregroundStyle(Color.flag)
              }
              if findings.count > 3 {
                Text("and \(findings.count - 3) more")
                  .font(.system(size: 11))
                  .foregroundStyle(Color.flag.opacity(0.8))
              }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.rec.opacity(0.08)))
          }
          let feed = session.events.suffix(lines)
          if !feed.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
              ForEach(feed) { FeedRow(event: $0, compact: true) }
            }
            .padding(.top, 1)
          }
        }
      }
      .padding(10)
    }
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    .accessibilityLabel("\(session.agent) in \(session.place), recording for \(Format.duration(session.duration(now: now))), \(Format.plural(flags, "flag"))")
    .accessibilityHint("Opens the session")
  }

  private struct Stat: View {
    let value: Int
    let label: String
    var red = false

    var body: some View {
      HStack(spacing: 3) {
        Text(value.formatted()).font(.system(size: 12, weight: .semibold).monospacedDigit())
        Text(label).font(.system(size: 11.5))
      }
      .foregroundStyle(red ? Color.flag : .secondary)
    }
  }
}

private struct RecentRow: View {
  @Environment(AppModel.self) private var model
  let session: Session

  var body: some View {
    HoverRow(action: { model.openSession(session.id) }) {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 6) {
            Text(session.agent).font(.system(size: 12.5, weight: .medium))
            Text(session.place)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.head)
          }
          Text("\(Format.when(session.start)) · \(Format.duration(session.duration(now: session.end ?? session.start)))")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        Spacer(minLength: 6)
        FlagCount(count: session.findings.count)
        Image(systemName: "chevron.right")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.tertiary)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
    }
    .accessibilityLabel("\(session.agent) in \(session.place), \(Format.when(session.start)), \(Format.plural(session.findings.count, "flag"))")
    .accessibilityHint("Opens the session")
  }
}

/// Why recording didn't start, and the one thing to do about it.
struct FailureBox: View {
  @Environment(AppModel.self) private var model
  let message: String
  let hint: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if hint == "full_disk_access" {
        Text("macOS needs one more step")
          .font(.system(size: 12, weight: .semibold))
        Text("Turn on bodycam in Full Disk Access, then start recording again.")
          .font(.system(size: 11.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button("Open Full Disk Access") { FullDiskAccess.open() }
          .controlSize(.small)
      } else {
        Text(message)
          .font(.system(size: 11.5, design: .monospaced))
          .foregroundStyle(.secondary)
          .lineLimit(4)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
        Button("Open the engine log") { NSWorkspace.shared.open(model.paths.engineLog) }
          .controlSize(.small)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.rec.opacity(0.09)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.rec.opacity(0.25)))
  }
}

enum FullDiskAccess {
  static func open() {
    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
  }
}
