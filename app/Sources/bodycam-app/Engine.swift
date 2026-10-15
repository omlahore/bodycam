import AppKit

/// Starting and stopping the bodycam engine, as app/ENGINE.md describes.
extension AppModel {
  var extraAgents: [String] {
    (UserDefaults.standard.string(forKey: "extraAgents") ?? "")
      .components(separatedBy: CharacterSet(charactersIn: ", \n"))
      .filter { !$0.isEmpty }
  }

  /// Asks for the password through the standard macOS prompt and starts the engine as root.
  func start() {
    guard !engine.isOn else { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: paths.events.deletingLastPathComponent(), withIntermediateDirectories: true)
    // The reports keep the history, so a big events file only needs to keep its last run around.
    if let size = (try? fm.attributesOfItem(atPath: paths.events.path)[.size] as? NSNumber)?.intValue, size > 16 << 20 {
      let old = paths.events.deletingPathExtension().appendingPathExtension("1.jsonl")
      try? fm.removeItem(at: old)
      try? fm.moveItem(at: paths.events, to: old)
    }
    if !fm.fileExists(atPath: paths.events.path) { fm.createFile(atPath: paths.events.path, contents: nil) }
    guard fm.createFile(atPath: paths.runFile.path, contents: nil) else {
      engine = .failed(message: "bodycam couldn't write to \(tilde(paths.logs.path)).", hint: nil)
      return
    }
    engineLogStart = (try? fm.attributesOfItem(atPath: paths.engineLog.path)[.size] as? NSNumber)?.uint64Value ?? 0
    engine = .starting

    var parts = [
      shellQuote(paths.engine.path), "--quiet", "--owner", "\(getuid())",
      "--events", shellQuote(paths.events.path), "--run-file", shellQuote(paths.runFile.path),
      "--parent-pid", "\(getpid())", "--agent", "sketchy-agent",
    ]
    for name in extraAgents { parts += ["--agent", shellQuote(name)] }
    let command = parts.joined(separator: " ") + " > /dev/null 2>> " + shellQuote(paths.engineLog.path) + " &"
    let prompt = "bodycam needs your password to start Apple's eslogger. Your agents keep running as you."
    let source = "do shell script \"\(appleScriptEscape(command))\" with prompt \"\(appleScriptEscape(prompt))\" with administrator privileges"

    DispatchQueue.global(qos: .userInitiated).async {
      var error: NSDictionary?
      NSAppleScript(source: source)?.executeAndReturnError(&error)
      let code = error?[NSAppleScript.errorNumber] as? Int
      let message = error?[NSAppleScript.errorMessage] as? String
      DispatchQueue.main.async {
        MainActor.assumeIsolated { self.started(errorCode: code, message: message) }
      }
    }
  }

  private func started(errorCode: Int?, message: String?) {
    guard engine == .starting else { return }
    if let errorCode {
      try? FileManager.default.removeItem(at: paths.runFile)
      pendingDemo = false
      // -128 is the Cancel button in the password prompt.
      engine = errorCode == -128 ? .off : .failed(message: message ?? "macOS didn't start the recorder.", hint: nil)
      return
    }
    // The engine writes a status line as soon as eslogger sends its first event.
    arm(after: 12) { model in
      guard model.engine == .starting else { return }
      model.pendingDemo = false
      try? FileManager.default.removeItem(at: model.paths.runFile)
      model.engine = .failed(message: model.lastEngineError() ?? "The recorder didn't start.", hint: nil)
    }
  }

  /// Stops without a password: the engine stops once its run file is gone.
  func stop() {
    guard engine == .watching || engine == .starting else { return }
    try? FileManager.default.removeItem(at: paths.runFile)
    pendingDemo = false
    engine = .stopping
    arm(after: 6) { model in
      guard model.engine == .stopping else { return }
      model.closeOpenSessions(at: nil)
      model.engine = .off
    }
  }

  func toggle() {
    if engine == .watching { stop() } else { start() }
  }

  /// Runs the pretend agent in the app's Resources once recording, starting recording first if needed.
  func tryDemo() {
    switch engine {
    case .watching:
      runDemo()
    case .starting:
      pendingDemo = true
    case .off, .failed:
      pendingDemo = true
      start()
    case .stopping:
      break
    }
  }

  func runDemo() {
    guard !demoRunning, let script = Bundle.main.url(forResource: "sketchy-agent", withExtension: nil) else { return }
    let p = Process()
    p.executableURL = script
    p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    p.terminationHandler = { _ in
      DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.demoRunning = false } }
    }
    do {
      try p.run()
      demoRunning = true
    } catch {
      demoRunning = false
    }
  }

  /// Quitting stops the engine too; it also watches this process.
  func shutdown() {
    if engine.isOn { try? FileManager.default.removeItem(at: paths.runFile) }
  }

  private func arm(after seconds: Double, _ body: @escaping (AppModel) -> Void) {
    watchdog?.cancel()
    let item = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.pollNow()
        body(self)
      }
    }
    watchdog = item
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
  }

  /// The last thing the engine wrote to engine.log since this start.
  func lastEngineError() -> String? {
    guard let handle = FileHandle(forReadingAtPath: paths.engineLog.path) else { return nil }
    defer { try? handle.close() }
    try? handle.seek(toOffset: engineLogStart)
    let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    return text.split(separator: "\n").last.map { String($0).trimmingCharacters(in: .whitespaces) }
  }
}

func shellQuote(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func appleScriptEscape(_ s: String) -> String {
  s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
}

func tilde(_ path: String) -> String {
  (path as NSString).abbreviatingWithTildeInPath
}
