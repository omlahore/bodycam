import AppKit
import SwiftUI

/// `bodycam-app --snapshot <dir> --events <events.jsonl>` renders the real views with the
/// sessions in that file to 2x PNGs, in light and dark, for the README and the website.
@MainActor
enum Snapshots {
  /// Set while rendering, so the REC light holds still.
  static var on = false

  static func run(into dir: String, events: String?) {
    guard let events else {
      FileHandle.standardError.write("usage: bodycam-app --snapshot <dir> --events <events.jsonl>\n".data(using: .utf8)!)
      exit(2)
    }
    on = true
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let model = AppModel.shared
    model.load(events, includeReports: false, assumeRunning: true)
    let all = model.active + model.recent
    let last = all.flatMap(\.events).map(\.time).max() ?? Date()
    model.snapshotNow = last.addingTimeInterval(4)

    // The session with the most to look at makes the best window.
    let featured = all.max { $0.findings.count < $1.findings.count }
    let flagged = model.active.first.flatMap { s in s.flagged.first.map { (s, $0) } }
      ?? all.lazy.compactMap { s in s.flagged.first.map { (s, $0) } }.first

    for dark in [false, true] {
      let suffix = dark ? "dark" : "light"
      app.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
      render(Chrome(radius: 14) { PopoverView() }, "popover-\(suffix)", dir, dark: dark)
      if let featured {
        render(SessionView(id: featured.id), "session-\(suffix)", dir, dark: dark,
          title: featured.windowTitle, size: NSSize(width: 780, height: 720))
      }
      model.engine = .off
      render(Chrome(radius: 16) { WelcomeView() }, "welcome-\(suffix)", dir, dark: dark)
      model.engine = .watching
      if let (session, event) = flagged {
        let text = Notifier.text(for: event, in: session)
        render(Banner(title: text.title, message: text.body), "notification-\(suffix)", dir, dark: dark)
      }
    }
    print("snapshots in \(dir)")
  }

  static func render<V: View>(
    _ view: V, _ name: String, _ dir: String, dark: Bool, title: String? = nil, size: NSSize? = nil
  ) {
    // The window is never key, so tell the controls to draw as if it were.
    let host = NSHostingView(rootView: view.environment(AppModel.shared).environment(\.controlActiveState, .key))
    let fit = size ?? host.fittingSize
    let window = NSWindow(
      contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: fit),
      styleMask: title != nil ? [.titled, .closable, .miniaturizable, .resizable] : [.borderless],
      backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    window.isReleasedWhenClosed = false
    window.ignoresMouseEvents = true
    if let title {
      window.title = title
    } else {
      window.isOpaque = false
      window.backgroundColor = .clear
    }
    window.contentView = host
    window.setContentSize(fit)
    window.alphaValue = 0
    window.orderFrontRegardless()
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))

    let target = title != nil ? (host.superview ?? host) : host
    target.layoutSubtreeIfNeeded()
    let bounds = target.bounds
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(bounds.width * 2), pixelsHigh: Int(bounds.height * 2),
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return }
    rep.size = bounds.size
    target.cacheDisplay(in: bounds, to: rep)
    let url = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
    try? (title != nil ? rounded(rep) : rep).representation(using: .png, properties: [:])?.write(to: url)
    window.orderOut(nil)
    window.close()
  }

  /// Gives a captured window the rounded corners it has on screen.
  static func rounded(_ rep: NSBitmapImageRep) -> NSBitmapImageRep {
    guard let out = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return rep }
    out.size = rep.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let rect = NSRect(origin: .zero, size: rep.size)
    NSBezierPath(roundedRect: rect, xRadius: 16, yRadius: 16).addClip()
    rep.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    return out
  }
}

/// The popover and welcome window as they sit on screen: rounded, with a soft shadow.
private struct Chrome<Content: View>: View {
  let radius: CGFloat
  @ViewBuilder let content: Content

  var body: some View {
    content
      .background(Color(nsColor: .windowBackgroundColor))
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: radius, style: .continuous)
          .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
      .padding(36)
  }
}

/// What a flag notification looks like, drawn the way macOS shows banners.
private struct Banner: View {
  let title: String
  let message: String

  var body: some View {
    HStack(alignment: .center, spacing: 11) {
      Image(nsImage: NSApp.applicationIconImage)
        .resizable()
        .interpolation(.high)
        .frame(width: 38, height: 38)
      VStack(alignment: .leading, spacing: 2) {
        HStack(alignment: .firstTextBaseline) {
          Text(title)
            .font(.system(size: 13, weight: .semibold))
            .lineLimit(1)
          Spacer(minLength: 6)
          Text("now")
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
        }
        Text(message)
          .font(.system(size: 13))
          .lineLimit(2)
          .foregroundStyle(.primary.opacity(0.85))
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 12)
    .frame(width: 370)
    .background(Color(nsColor: .windowBackgroundColor).opacity(0.97))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    .shadow(color: .black.opacity(0.2), radius: 14, y: 6)
    .padding(30)
  }
}
