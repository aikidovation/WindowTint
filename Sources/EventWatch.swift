import AppKit
import ApplicationServices

/// Accessibility observers, workspace notifications, and a ~4 Hz timer. All of them
/// schedule one coalesced refresh. Without Accessibility permission, only the timer runs.
final class EventWatch {
    var onRefresh: (() -> Void)?
    private var observers: [pid_t: AppAXObserver] = [:]
    private var timer: Timer?
    private var pending = false
    private var lastRefresh = Date.distantPast
    private var lastAttempt: [pid_t: Date] = [:]
    private var lastWindowCounts: [pid_t: Int] = [:]
    private var notificationTokens: [NSObjectProtocol] = []
    private static weak var current: EventWatch?

    init() {
        EventWatch.current = self
    }

    func start() {
        EventWatch.current = self
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification,
        ]
        for name in names {
            // The returned token is the observer. Releasing it removes the notification.
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.schedule()
            }
            notificationTokens.append(token)
        }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.schedule()
        }
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        schedule()
    }

    deinit {
        timer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        for token in notificationTokens {
            center.removeObserver(token)
        }
    }

    /// Shows the system Accessibility prompt when this process is not trusted yet.
    func requestAccessibilityPrompt() {
        guard !AXIsProcessTrusted() else { return }
        let key = kAXTrustedCheckOptionPrompt as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func note(windowCounts: [pid_t: Int]) {
        for (pid, count) in windowCounts {
            guard let observer = observers[pid], lastWindowCounts[pid] != count else { continue }
            lastWindowCounts[pid] = count
            observer.subscribeToWindows()
        }
        for pid in Array(lastWindowCounts.keys) where windowCounts[pid] == nil {
            lastWindowCounts.removeValue(forKey: pid)
        }
    }

    fileprivate static func scheduleFromObserver() {
        current?.schedule()
    }

    private func schedule() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.schedule() }
            return
        }
        guard !pending else { return }
        pending = true
        let delay = max(0, lastRefresh.addingTimeInterval(0.05).timeIntervalSinceNow)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.lastRefresh = Date()
            self.syncObservers()
            self.onRefresh?()
        }
    }

    private func syncObservers() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        let live = Set(apps.map(\.processIdentifier))
        for pid in Array(observers.keys) where !live.contains(pid) {
            observers.removeValue(forKey: pid)
            lastWindowCounts.removeValue(forKey: pid)
            lastAttempt.removeValue(forKey: pid)
        }
        // Timer-only until Accessibility is granted. Retrying Create on every tick is noisy.
        guard AXIsProcessTrusted() else {
            if !observers.isEmpty { observers.removeAll() }
            return
        }
        for app in apps {
            let pid = app.processIdentifier
            if observers[pid] != nil { continue }
            if let last = lastAttempt[pid], Date().timeIntervalSince(last) < 2 { continue }
            lastAttempt[pid] = Date()
            if let observer = AppAXObserver(pid: pid) {
                observers[pid] = observer
                lastWindowCounts.removeValue(forKey: pid)
            }
        }
    }
}

private func axObserverCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    EventWatch.scheduleFromObserver()
}

private final class AppAXObserver {
    let pid: pid_t
    private let observer: AXObserver
    private let application: AXUIElement

    init?(pid: pid_t) {
        var created: AXObserver?
        let error = AXObserverCreate(pid, axObserverCallback, &created)
        guard error == .success, let created else { return nil }
        self.pid = pid
        self.observer = created
        self.application = AXUIElementCreateApplication(pid)
        for name in Self.applicationNotifications {
            _ = AXObserverAddNotification(created, application, name as CFString, nil)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(created),
            .commonModes
        )
    }

    deinit {
        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Moved and resized are delivered for the window element, so subscribe there too.
    /// Adding a notification that is already registered returns an error we ignore.
    func subscribeToWindows() {
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &raw)
        guard error == .success else { return }
        let windows: [AXUIElement]
        if let typed = raw as? [AXUIElement] {
            windows = typed
        } else if let array = raw as? NSArray {
            windows = array.compactMap { $0 as? AXUIElement }
        } else {
            return
        }
        for window in windows {
            for name in Self.windowNotifications {
                _ = AXObserverAddNotification(observer, window, name as CFString, nil)
            }
        }
    }

    private static let applicationNotifications = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXWindowCreatedNotification,
        kAXUIElementDestroyedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXFocusedWindowChangedNotification,
    ]

    private static let windowNotifications = [
        kAXMovedNotification,
        kAXResizedNotification,
        kAXWindowMiniaturizedNotification,
        kAXWindowDeminiaturizedNotification,
        kAXUIElementDestroyedNotification,
    ]
}
