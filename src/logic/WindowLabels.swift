import Cocoa

/// Custom labels for windows, shown only inside the AltTab switcher.
///
/// Keys are **per OS window** (`CGWindowID`), not per app or per title, so two
/// windows of the same app never share a label.
class WindowLabels {
    static let defaultsKey = "windowLabels"
    private static weak var editingThumbnail: ThumbnailView?

    /// Stable for the lifetime of the OS window. Does not use title (titles collide).
    static func makeKey(for window: Window) -> String {
        if let wid = window.cgWindowId {
            return "id:\(wid)"
        }
        // Windowless app row: one entry per process
        return "app:\(window.application.pid)"
    }

    static func all() -> [String: String] {
        CachedUserDefaults.json(defaultsKey, [String: String].self)
    }

    static func label(for window: Window) -> String? {
        let key = makeKey(for: window)
        let stored = all()
        guard let label = stored[key], !label.isEmpty else { return nil }
        return label
    }

    static func setLabel(_ rawLabel: String, for window: Window) {
        var stored = sanitize(all())
        let trimmed = rawLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = makeKey(for: window)

        if trimmed.isEmpty {
            stored.removeValue(forKey: key)
        } else {
            stored[key] = trimmed
        }
        Preferences.set(defaultsKey, stored)
    }

    /// Drop legacy keys (old scheme was `bundleId + title`, which merged same-app windows).
    private static func sanitize(_ stored: [String: String]) -> [String: String] {
        stored.filter { key, _ in
            key.hasPrefix("id:") || key.hasPrefix("app:")
        }
    }

    static func originalTitleDescription(for window: Window) -> String {
        let appName = window.application.localizedName
        let windowTitle = window.title
        if Preferences.onlyShowApplications() || Preferences.showTitles == .appName {
            return appName ?? ""
        }
        if Preferences.showTitles == .appNameAndWindowTitle {
            return [appName, windowTitle].compactMap { $0 }.joined(separator: " - ")
        }
        return windowTitle ?? appName ?? ""
    }

    static func beginEditing(_ view: ThumbnailView) {
        if let existing = editingThumbnail, existing !== view {
            existing.cancelLabelEditing()
        }
        editingThumbnail = view
        App.app.isEditingWindowLabel = true
        App.app.forceDoNothingOnRelease = true
    }

    static func endEditing(_ view: ThumbnailView) {
        if editingThumbnail === view {
            editingThumbnail = nil
        }
        App.app.isEditingWindowLabel = false
        App.app.forceDoNothingOnRelease = false
    }

    static func cancelEditingIfNeeded() {
        editingThumbnail?.cancelLabelEditing()
    }
}
