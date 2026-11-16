import AppKit
import ApplicationServices

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static let shared = AppDelegate()
    private static let githubURL = URL(string: "https://github.com/aikidovation/WindowTint")!
    private static let accessibilityURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private let settings = Settings()
    private let overlays = OverlayController()
    private let watch = EventWatch()
    private var statusItem: NSStatusItem!
    private var enabledItem: NSMenuItem!
    private var tintItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var accessItem: NSMenuItem!
    private var borderItems: [NSMenuItem] = []
    private var baselineWindowIDs: Set<Int> = []
    private var settlingSpace = false
    private var spaceSettle: DispatchWorkItem?

    static func main() {
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        watch.onRefresh = { [weak self] in
            self?.refresh()
        }
        watch.onSpaceChange = { [weak self] in
            self?.beginSpaceSettle()
        }
        overlays.onNeedsRefresh = { [weak self] in
            self?.refresh()
        }
        watch.requestAccessibilityPrompt()
        watch.start()
    }

    private func refresh() {
        let windows = WindowList.copyOnScreen()
        let ids = Set(windows.map(\.windowNumber))
        // A Space switch replaces most of the on-screen set even if the notification is late.
        if isWholesaleChange(from: baselineWindowIDs, to: ids) {
            baselineWindowIDs = ids
            beginSpaceSettle()
            watch.note(windowCounts: pidCounts(windows))
            return
        }
        if settlingSpace {
            watch.note(windowCounts: pidCounts(windows))
            return
        }
        baselineWindowIDs = ids
        let counts = overlays.refresh(windows: windows, settings: settings)
        watch.note(windowCounts: counts)
    }

    /// Hides every border immediately, then draws the current Space again once the animation has been quiet for 0.35 s.
    private func beginSpaceSettle() {
        settlingSpace = true
        overlays.hideAll()
        spaceSettle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finishSpaceSettle()
        }
        spaceSettle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func finishSpaceSettle() {
        settlingSpace = false
        spaceSettle = nil
        let windows = WindowList.copyOnScreen()
        baselineWindowIDs = Set(windows.map(\.windowNumber))
        let counts = overlays.refresh(windows: windows, settings: settings)
        watch.note(windowCounts: counts)
    }

    private func isWholesaleChange(from previous: Set<Int>, to current: Set<Int>) -> Bool {
        guard !previous.isEmpty else { return false }
        let kept = previous.intersection(current).count
        return kept * 2 < previous.count
    }

    private func pidCounts(_ windows: [WindowRecord]) -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for window in windows {
            counts[window.pid, default: 0] += 1
        }
        return counts
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "WindowTint") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "WT"
            }
            button.toolTip = "WindowTint"
        }

        enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        tintItem = NSMenuItem(title: "Tint", action: #selector(toggleTint), keyEquivalent: "")
        loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        accessItem = NSMenuItem(title: "Grant Accessibility…", action: #selector(grantAccessibility), keyEquivalent: "")

        let menu = NSMenu()
        menu.delegate = self
        add(enabledItem, to: menu)

        let borderMenu = NSMenu()
        for width in [2, 4, 6] {
            let item = NSMenuItem(title: "\(width) pt", action: #selector(selectBorderWidth(_:)), keyEquivalent: "")
            item.tag = width
            item.target = self
            borderItems.append(item)
            borderMenu.addItem(item)
        }
        let borderItem = NSMenuItem(title: "Border Width", action: nil, keyEquivalent: "")
        borderItem.submenu = borderMenu
        menu.addItem(borderItem)

        add(tintItem, to: menu)
        menu.addItem(.separator())
        add(loginItem, to: menu)
        let github = NSMenuItem(title: "View on GitHub", action: #selector(openGitHub), keyEquivalent: "")
        add(github, to: menu)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit WindowTint", action: #selector(quit), keyEquivalent: "q")
        add(quit, to: menu)
        accessItem.target = self
        statusItem.menu = menu
        updateMenuState()
    }

    private func add(_ item: NSMenuItem, to menu: NSMenu) {
        item.target = self
        menu.addItem(item)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuState()
        let trusted = AXIsProcessTrusted()
        let listed = accessItem.menu != nil
        if trusted, listed {
            menu.removeItem(accessItem)
        } else if !trusted, !listed {
            let index = menu.index(of: loginItem)
            if index >= 0 { menu.insertItem(accessItem, at: index) }
        }
    }

    private func updateMenuState() {
        enabledItem.state = settings.isEnabled ? .on : .off
        tintItem.state = settings.tintEnabled ? .on : .off
        loginItem.state = settings.launchesAtLogin ? .on : .off
        let width = Int(settings.borderWidth)
        for item in borderItems {
            item.state = item.tag == width ? .on : .off
        }
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
        updateMenuState()
        refresh()
    }

    @objc private func toggleTint() {
        settings.tintEnabled.toggle()
        updateMenuState()
        refresh()
    }

    @objc private func selectBorderWidth(_ sender: NSMenuItem) {
        settings.borderWidth = CGFloat(sender.tag)
        updateMenuState()
        refresh()
    }

    @objc private func toggleLogin() {
        settings.setLaunchesAtLogin(!settings.launchesAtLogin)
        updateMenuState()
    }

    @objc private func grantAccessibility() {
        NSWorkspace.shared.open(Self.accessibilityURL)
    }

    @objc private func openGitHub() {
        NSWorkspace.shared.open(Self.githubURL)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
