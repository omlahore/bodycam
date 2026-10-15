import AppKit
import SwiftUI

/// The first-run window: what bodycam does, why it asks for a password, and two ways to start.
struct WelcomeView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismissWindow) private var dismissWindow

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 22) {
        VStack(spacing: 10) {
          Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 84, height: 84)
            .accessibilityHidden(true)
          Text("See what your AI agents do")
            .font(.system(size: 22, weight: .bold))
          Text("bodycam records the commands your coding agents run, the files they change, the secrets they read and the servers they connect to.")
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 420)
        }
        VStack(alignment: .leading, spacing: 14) {
          Point(
            symbol: "lock.laptopcomputer", title: "Nothing leaves your Mac",
            text: "Your reports stay in ~/Library/Logs/bodycam.")
          Point(
            symbol: "key", title: "Why it asks for your password",
            text: "Apple's eslogger, which bodycam reads from, only runs as root. Your agents keep running as you.")
          Point(
            symbol: "hand.raised", title: "It records, it doesn't block",
            text: "To stop an agent doing something, use its permission settings or a sandbox.")
        }
        .frame(maxWidth: 430)
        status
      }
      .padding(.horizontal, 40)
      .padding(.top, 32)
      .padding(.bottom, 24)
      Spacer(minLength: 0)
      Divider()
      buttons
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
    .frame(width: 540)
    .fixedSize(horizontal: false, vertical: true)
    .onDisappear { UserDefaults.standard.set(true, forKey: "welcomed") }
  }

  @ViewBuilder
  private var status: some View {
    switch model.engine {
    case .failed(let message, let hint):
      if hint == "full_disk_access" {
        Step(
          title: "One more step: Full Disk Access",
          text: "macOS didn't let bodycam read events yet. Turn on bodycam in Full Disk Access, then start recording again.",
          button: "Open Full Disk Access", action: FullDiskAccess.open)
      } else {
        Step(title: "Recording didn't start", text: message, button: nil, action: {})
      }
    case .starting:
      HStack(spacing: 8) {
        ProgressView().controlSize(.small)
        Text("Enter your Mac password in the dialog to start.")
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
      }
    case .watching:
      HStack(alignment: .top, spacing: 10) {
        RecDot(size: 9)
          .padding(.top, 4)
        VStack(alignment: .leading, spacing: 2) {
          Text(model.demoRunning ? "Recording the demo" : "bodycam is recording")
            .font(.system(size: 13, weight: .semibold))
          Text(model.demoRunning
            ? "Its flags show up in the menu bar as it runs."
            : "It lives in the menu bar. Start your agents as usual.")
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .frame(maxWidth: 430)
    case .off, .stopping:
      EmptyView()
    }
  }

  private var buttons: some View {
    HStack(spacing: 10) {
      Button("Not now") { close() }
        .keyboardShortcut(.cancelAction)
        .controlSize(.large)
      Spacer()
      if model.engine == .watching {
        Button("Done") { close() }
          .keyboardShortcut(.defaultAction)
          .controlSize(.large)
      } else {
        Button("Try the demo") { model.tryDemo() }
          .buttonStyle(HiVisButtonStyle(large: true))
          .disabled(model.engine == .starting)
          .help("Starts recording, then runs a harmless pretend agent that bodycam flags")
        Button { model.start() } label: {
          Label("Start recording", systemImage: "record.circle")
        }
        .buttonStyle(RecordButtonStyle())
        .keyboardShortcut(.defaultAction)
        .disabled(model.engine == .starting)
      }
    }
  }

  private func close() {
    UserDefaults.standard.set(true, forKey: "welcomed")
    dismissWindow(id: "welcome")
  }
}

private struct Point: View {
  let symbol: String
  let title: String
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: symbol)
        .font(.system(size: 17))
        .foregroundStyle(.secondary)
        .frame(width: 26)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .semibold))
        Text(text)
          .font(.system(size: 12.5))
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
    }
    .accessibilityElement(children: .combine)
  }
}

private struct Step: View {
  let title: String
  let text: String
  let button: String?
  let action: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 13, weight: .semibold))
      Text(text)
        .font(.system(size: 12.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
      if let button {
        Button(button, action: action)
      }
    }
    .frame(maxWidth: 430, alignment: .leading)
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.hiVis.opacity(0.14)))
    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.hiVis.opacity(0.7)))
  }
}
