import AppKit
import SwiftUI

extension Color {
  /// Recording red #E8261B for the REC light and fills.
  static let rec = Color(nsColor: Glyph.rec)
  /// Red for text: #E8261B is a little dark on dark backgrounds and a little light on white.
  static let flag = Color(nsColor: NSColor(name: nil) { a in
    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      ? NSColor(srgbRed: 1, green: 0x5C / 255, blue: 0x50 / 255, alpha: 1)
      : NSColor(srgbRed: 0xC8 / 255, green: 0x1E / 255, blue: 0x16 / 255, alpha: 1)
  })
  /// Hi-vis yellow #FFD23A, used sparingly.
  static let hiVis = Color(red: 1, green: 0xD2 / 255, blue: 0x3A / 255)
  static let ink = Color(red: 0x12 / 255, green: 0x12 / 255, blue: 0x12 / 255)

  static func verb(_ verb: String) -> Color {
    switch verb {
    case "run": return .blue
    case "new", "edit": return .green
    case "delete": return .orange
    case "read", "flag": return .flag
    case "net": return .teal
    default: return .primary
    }
  }
}

enum Format {
  /// "0:42", "4:12", "1:02:33" for running clocks.
  static func clock(_ t: TimeInterval) -> String {
    let s = Int(t)
    return s >= 3600
      ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
      : String(format: "%d:%02d", s / 60, s % 60)
  }

  /// "4s", "1m 23s", "1h 2m".
  static func duration(_ t: TimeInterval) -> String {
    let s = Int(t.rounded())
    if s < 60 { return "\(s)s" }
    if s < 3600 { return s % 60 == 0 ? "\(s / 60)m" : "\(s / 60)m \(s % 60)s" }
    return s / 60 % 60 == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(s / 60 % 60)m"
  }

  static let feedTime: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
  }()

  static let time: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("jjmm")
    return f
  }()

  static let day: DateFormatter = {
    let f = DateFormatter()
    f.setLocalizedDateFormatFromTemplate("dMMM")
    return f
  }()

  /// "Today 02:34", "Yesterday 18:02", "14 Oct 18:02".
  static func when(_ d: Date) -> String {
    let cal = Calendar.current
    let day = cal.isDateInToday(d) ? "Today" : cal.isDateInYesterday(d) ? "Yesterday" : Self.day.string(from: d)
    return "\(day) \(time.string(from: d))"
  }

  static func plural(_ n: Int, _ word: String) -> String {
    n == 1 ? "1 \(word)" : "\(n.formatted()) \(word)s"
  }
}

/// One line of the live feed, laid out like the terminal: time, who, verb, what, and why it's flagged.
struct FeedRow: View {
  let event: Event
  var compact = false

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text(Format.feedTime.string(from: event.time))
        .foregroundStyle(.tertiary)
      Text(event.who)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .frame(width: compact ? 52 : 72, alignment: .leading)
      Text(event.verb)
        .foregroundStyle(Color.verb(event.verb))
        .frame(width: 40, alignment: .leading)
      VStack(alignment: .leading, spacing: 1) {
        Text(event.what)
          .foregroundStyle(event.flag ? Color.flag : .primary)
          .lineLimit(1)
          .truncationMode(.middle)
        if !event.note.isEmpty {
          Text("! " + event.label)
            .foregroundStyle(event.flag ? Color.flag : .orange)
            .lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .font(.system(size: compact ? 10.5 : 11.5, design: .monospaced))
    .accessibilityElement(children: .combine)
  }
}

/// The REC light, pulsing gently while recording.
struct RecDot: View {
  var size: CGFloat = 8
  var pulsing = true
  @State private var dim = false
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    Circle()
      .fill(Color.rec)
      .frame(width: size, height: size)
      .shadow(color: Color.rec.opacity(0.6), radius: dim ? 1 : 3)
      .opacity(dim ? 0.45 : 1)
      .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: dim)
      .onAppear {
        guard pulsing, !reduceMotion, !Snapshots.on else { return }
        dim = true
      }
      .accessibilityHidden(true)
  }
}

/// "REC 4:12" in a red-tinted capsule.
struct RecBadge: View {
  let elapsed: TimeInterval
  var pulsing = true

  var body: some View {
    HStack(spacing: 5) {
      RecDot(size: 7, pulsing: pulsing)
      Text("REC").font(.system(size: 10, weight: .bold)).kerning(0.5)
      Text(Format.clock(elapsed)).font(.system(size: 11, weight: .medium).monospacedDigit())
    }
    .foregroundStyle(Color.flag)
    .padding(.horizontal, 8)
    .padding(.vertical, 3.5)
    .background(Capsule().fill(Color.rec.opacity(0.12)))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Recording for \(Format.duration(elapsed))")
  }
}

/// "3 flags" in red, or a calm "No flags".
struct FlagCount: View {
  let count: Int

  var body: some View {
    if count > 0 {
      Text(Format.plural(count, "flag"))
        .font(.caption.weight(.semibold))
        .foregroundStyle(Color.flag)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.rec.opacity(0.12)))
    } else {
      Text("No flags")
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

/// The yellow "Try the demo" button, ink on hi-vis.
struct HiVisButtonStyle: ButtonStyle {
  var large = false
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: large ? 13 : 12, weight: .semibold))
      .foregroundStyle(Color.ink)
      .padding(.horizontal, large ? 14 : 11)
      .frame(minHeight: large ? 28 : 24)
      .background(
        RoundedRectangle(cornerRadius: large ? 8 : 7, style: .continuous)
          .fill(Color.hiVis.opacity(configuration.isPressed ? 0.8 : 1))
      )
      .overlay(
        RoundedRectangle(cornerRadius: large ? 8 : 7, style: .continuous)
          .strokeBorder(Color.black.opacity(0.1))
      )
      .opacity(isEnabled ? 1 : 0.5)
      .contentShape(Rectangle())
  }
}

/// The red Start recording button. Drawn by hand so it stays red when its window isn't key.
struct RecordButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 13, weight: .medium))
      .foregroundStyle(.white)
      .padding(.horizontal, 14)
      .frame(minHeight: 28)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.rec.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.5))
      )
      .contentShape(Rectangle())
  }
}

/// A row that highlights under the pointer, for things you can click in the popover.
struct HoverRow<Content: View>: View {
  let action: () -> Void
  @ViewBuilder let content: Content
  @State private var hovering = false

  var body: some View {
    Button(action: action) {
      content
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(Color.primary.opacity(hovering ? 0.07 : 0))
    )
    .onHover { hovering = $0 }
  }
}

/// Section titles in the popover and windows.
struct SectionTitle: View {
  let title: String
  var trailing: AnyView?

  var body: some View {
    HStack {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer()
      if let trailing { trailing }
    }
  }
}

extension Session {
  /// "~/code/invoice-api", or the agent's pid when there is no project.
  var place: String { project.isEmpty ? "pid \(pid)" : project }

  var windowTitle: String { "\(agent), \(Format.when(start))" }
}
