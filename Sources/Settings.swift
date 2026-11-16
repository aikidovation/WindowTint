import AppKit
import ServiceManagement

/// UserDefaults for `com.aikidovation.WindowTint` (the app's bundle id, non-sandboxed).
final class Settings {
    static let enabledKey = "enabled"
    static let borderWidthKey = "borderWidth"
    static let tintEnabledKey = "tintEnabled"
    static let colorOverridesKey = "colorOverrides"
    static let excludedBundleIDsKey = "excludedBundleIDs"

    /// Faint wash over the window. The menu only toggles it; the amount is fixed.
    static let tintOpacity: CGFloat = 0.06
    /// Outer corner radius of the border, in points. macOS window corners are about 10–12 pt.
    static let cornerRadius: CGFloat = 12

    init() {
        UserDefaults.standard.register(defaults: [
            Self.enabledKey: true,
            Self.borderWidthKey: 4.0,
            Self.tintEnabledKey: false,
        ])
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    /// 2, 4, or 6. Anything else reads back as the default 4.
    var borderWidth: CGFloat {
        get {
            let value = UserDefaults.standard.double(forKey: Self.borderWidthKey)
            switch value {
            case 2, 6: return value
            default: return 4
            }
        }
        set { UserDefaults.standard.set(Double(newValue), forKey: Self.borderWidthKey) }
    }

    var tintEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.tintEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.tintEnabledKey) }
    }

    var excludedBundleIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.excludedBundleIDsKey) ?? [])
    }

    func overrideHex(for bundleID: String) -> String? {
        let dict = UserDefaults.standard.dictionary(forKey: Self.colorOverridesKey)
        return dict?[bundleID] as? String
    }

    var launchesAtLogin: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    /// Register or remove this app as a login item. Opens Login Items settings if macOS still needs approval.
    func setLaunchesAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                if service.status != .enabled && service.status != .requiresApproval {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            NSLog("%@", "WindowTint could not update Launch at Login: \(error.localizedDescription)")
        }
        if enabled, SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
