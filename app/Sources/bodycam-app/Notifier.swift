import AppKit
import UserNotifications

/// A notification when something gets flagged. One per session every 15 seconds at most;
/// flags in between are summed up in one notification when the window ends.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
  static let shared = Notifier()
  static let window: TimeInterval = 15

  private var last: [String: Date] = [:]
  private var held: [String: [Event]] = [:]

  /// A bare binary run outside an .app has no bundle, and the notification center would crash it.
  private var center: UNUserNotificationCenter? {
    Bundle.main.bundleURL.pathExtension == "app" ? UNUserNotificationCenter.current() : nil
  }

  var enabled: Bool { UserDefaults.standard.object(forKey: "notifications") as? Bool ?? true }

  func setUp() {
    center?.delegate = self
  }

  func requestAuthorization() {
    guard enabled else { return }
    center?.requestAuthorization(options: [.alert]) { _, _ in }
  }

  func flagged(_ event: Event, in session: Session) {
    guard enabled, center != nil else { return }
    let id = session.id
    if let t = last[id], Date().timeIntervalSince(t) < Self.window {
      if held[id] == nil {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.window - Date().timeIntervalSince(t)) {
          MainActor.assumeIsolated { self.flushHeld(id) }
        }
      }
      held[id, default: []].append(event)
      return
    }
    last[id] = Date()
    post(Self.text(for: event, in: session), session: session)
  }

  private func flushHeld(_ id: String) {
    guard let events = held.removeValue(forKey: id), !events.isEmpty,
      let session = AppModel.shared.session(id)
    else { return }
    last[id] = Date()
    post(Self.summary(events, in: session), session: session)
  }

  /// "claude read an .env file", with the path and project underneath.
  static func text(for event: Event, in session: Session) -> (title: String, body: String) {
    let place = session.project.isEmpty ? "" : " in \(session.project)"
    return ("\(session.agent) \(event.label)", event.what + place)
  }

  static func summary(_ events: [Event], in session: Session) -> (title: String, body: String) {
    if events.count == 1 { return text(for: events[0], in: session) }
    let labels = events.map(\.label).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    let shown = labels.prefix(3).joined(separator: ", ")
    return ("\(session.agent): \(events.count) more things to look at", labels.count > 3 ? shown + " and more" : shown)
  }

  private func post(_ text: (title: String, body: String), session: Session) {
    let content = UNMutableNotificationContent()
    content.title = text.title
    content.body = text.body
    content.threadIdentifier = session.id
    content.userInfo = ["session": session.id]
    center?.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .list])
  }

  nonisolated func userNotificationCenter(
    _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    let id = response.notification.request.content.userInfo["session"] as? String
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        if let id { AppModel.shared.openSession(id) }
      }
    }
    completionHandler()
  }
}
