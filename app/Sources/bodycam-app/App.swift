import AppKit
import SwiftUI

@main
enum Main {
  static func main() {
    if let dir = argument("--snapshot") {
      Snapshots.run(into: dir, events: argument("--events"))
      return
    }
    BodycamApp.main()
  }
}

struct BodycamApp: App {
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate
  private let model = AppModel.shared

  var body: some Scene {
    MenuBarExtra {
      PopoverView()
        .environment(model)
    } label: {
      MenuBarLabel()
        .environment(model)
    }
    .menuBarExtraStyle(.window)

    WindowGroup("Session", id: "session", for: String.self) { $id in
      if let id {
        SessionView(id: id)
          .environment(model)
      }
    }
    .defaultSize(width: 780, height: 700)
    .commandsRemoved()

    Window("Welcome to bodycam", id: "welcome") {
      WelcomeView()
        .environment(model)
    }
    .windowResizability(.contentSize)
    .windowStyle(.hiddenTitleBar)
    .defaultPosition(.center)

    Settings {
      SettingsView()
        .environment(model)
    }
  }
}

/// The menu bar icon. It is always on screen, so it also does the launch work that needs a view.
struct MenuBarLabel: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(nsImage: Glyph.menuBar(recording: model.isRecording, unseen: model.unseenFlags))
      .accessibilityLabel(accessibility)
      .task {
        guard model.openWindowAction == nil else { return }
        model.openWindowAction = openWindow
        if !UserDefaults.standard.bool(forKey: "welcomed") {
          model.openWelcome()
        } else if UserDefaults.standard.bool(forKey: "startOnLaunch") {
          model.start()
        }
      }
  }

  private var accessibility: String {
    var s = model.isRecording ? "bodycam, recording" : model.engine == .watching ? "bodycam, watching" : "bodycam"
    if model.unseenFlags > 0 { s += ", \(Format.plural(model.unseenFlags, "new flag"))" }
    return s
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      Notifier.shared.setUp()
      AppModel.shared.launch()
    }
    // A menu bar app with a window open gets a Dock icon and a place in the app switcher.
    let center = NotificationCenter.default
    center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
      guard let w = note.object as? NSWindow, Self.isDocumentWindow(w) else { return }
      if NSApp.activationPolicy() != .regular {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
      }
    }
    center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
      let closing = note.object as? NSWindow
      DispatchQueue.main.async {
        let open = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isDocumentWindow($0) }
        if !open { NSApp.setActivationPolicy(.accessory) }
      }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { AppModel.shared.shutdown() }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

  static func isDocumentWindow(_ w: NSWindow) -> Bool {
    w.styleMask.contains(.titled) && !String(describing: type(of: w)).contains("MenuBarExtra")
  }
}
