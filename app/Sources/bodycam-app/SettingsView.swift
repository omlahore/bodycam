import AppKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @AppStorage("startOnLaunch") private var startOnLaunch = false
  @AppStorage("notifications") private var notifications = true
  @AppStorage("extraAgents") private var extraAgents = ""
  @State private var notificationsDenied = false
  @State private var engineVersion = ""

  var body: some View {
    Form {
      Section {
        Toggle("Start recording when bodycam opens", isOn: $startOnLaunch)
        TextField("Also watch for", text: $extraAgents, prompt: Text("my-agent, other-agent"))
      } header: {
        Text("Recording")
      } footer: {
        Text("bodycam already knows Claude Code, Codex, Gemini CLI, Cursor CLI, Aider, OpenCode, Amp, Crush, Qwen Code, GitHub Copilot CLI, Droid and Kiro. Names you add here count from the next time you start recording.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.leading)
          .frame(maxWidth: .infinity, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
      }
      Section("Notifications") {
        Toggle("Tell me when something gets flagged", isOn: $notifications)
          .onChange(of: notifications) { _, on in
            if on { Notifier.shared.requestAuthorization() }
            checkNotifications()
          }
        if notifications && notificationsDenied {
          HStack {
            Text("Notifications for bodycam are off in System Settings.")
              .font(.callout)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Open") {
              NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            }
          }
        }
      }
      Section("Reports") {
        LabeledContent("Saved in") {
          HStack {
            Text(tilde(model.paths.logs.path))
              .font(.system(.body, design: .monospaced))
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
            Button("Open") { model.openReportsFolder() }
          }
        }
      }
      Section("About") {
        LabeledContent("Version") {
          Text(engineVersion.isEmpty ? appVersion : "\(appVersion) (engine \(engineVersion))")
            .foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        HStack(spacing: 16) {
          Link("GitHub", destination: URL(string: "https://github.com/omlahore/bodycam")!)
          Link("Website", destination: URL(string: "https://omlahore.github.io/bodycam/")!)
          Link("Report a problem", destination: URL(string: "https://github.com/omlahore/bodycam/issues")!)
          Spacer()
          Button("Show welcome") { model.openWelcome() }
        }
      }
    }
    .formStyle(.grouped)
    .frame(width: 480)
    .fixedSize(horizontal: false, vertical: true)
    .task {
      checkNotifications()
      engineVersion = await Task.detached { [path = model.paths.engine.path] in Self.version(of: path) }.value
    }
  }

  private var appVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
  }

  private func checkNotifications() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let denied = settings.authorizationStatus == .denied
      DispatchQueue.main.async { notificationsDenied = denied }
    }
  }

  /// `bodycam --version` prints "bodycam 0.2.0".
  nonisolated static func version(of engine: String) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: engine)
    p.arguments = ["--version"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return "" }
    p.waitUntilExit()
    let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "bodycam ", with: "")
  }
}
