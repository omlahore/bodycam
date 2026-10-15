import AppKit

/// The menu bar icon: the bodycam device from assets/device.svg, simplified to read at 18 pt.
enum Glyph {
  static let height: CGFloat = 18
  static let width: CGFloat = 16

  /// A template image while idle, so macOS tints it. With the red REC light or the
  /// count of unseen flags it draws its own colors for the menu bar's appearance.
  static func menuBar(recording: Bool, unseen: Int) -> NSImage {
    let count = unseen > 99 ? "99+" : "\(unseen)"
    let font = NSFont.systemFont(ofSize: 9.5, weight: .bold)
    let countWidth = unseen > 0 ? max(13, (count as NSString).size(withAttributes: [.font: font]).width + 7) : 0
    let size = NSSize(width: width + (unseen > 0 ? countWidth + 2 : 0), height: height)
    let image = NSImage(size: size, flipped: true) { _ in
      // labelColor resolves against the menu bar's appearance while drawing, like a template image would.
      draw(in: NSRect(x: 0, y: 0, width: width, height: height), ink: .labelColor, recording: recording)
      if unseen > 0 {
        let pill = NSRect(x: width + 2, y: (height - 12) / 2 + 0.5, width: countWidth, height: 12)
        rec.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let w = (count as NSString).size(withAttributes: attrs)
        (count as NSString).draw(
          at: NSPoint(x: pill.midX - w.width / 2, y: pill.midY - w.height / 2), withAttributes: attrs)
      }
      return true
    }
    image.isTemplate = !recording && unseen == 0
    image.accessibilityDescription = recording ? "bodycam, recording" : "bodycam"
    return image
  }

  static let rec = NSColor(srgbRed: 0xE8 / 255, green: 0x26 / 255, blue: 0x1B / 255, alpha: 1)

  /// Draws the device in a flipped rect about 16 x 18 pt.
  static func draw(in r: NSRect, ink: NSColor, recording: Bool) {
    let cx = r.midX
    let body = NSBezierPath(roundedRect: NSRect(x: cx - 5.75, y: r.minY + 3, width: 11.5, height: 14.5), xRadius: 3.0, yRadius: 3.0)
    let lens = NSPoint(x: cx, y: r.minY + 11.6)
    body.append(circle(lens, 3.6))
    body.append(circle(lens, 1.7))
    let light = NSPoint(x: cx - 3.2, y: r.minY + 6.4)
    if !recording { body.append(circle(light, 1.0)) }
    body.windingRule = .evenOdd
    ink.setFill()
    body.fill()
    NSBezierPath(roundedRect: NSRect(x: cx - 3.0, y: r.minY + 0.6, width: 6.0, height: 3.6), xRadius: 1.2, yRadius: 1.2).fill()
    if recording {
      rec.setFill()
      circle(light, 1.6).fill()
    }
  }

  static func circle(_ c: NSPoint, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: NSRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2))
  }
}
