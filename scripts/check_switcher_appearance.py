#!/usr/bin/env python3
"""Compile and exercise the actual appearance picker without the full Xcode app.

Run from any directory. Prints the location of light and dark PNG previews.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "src/ui/main-window/ThumbnailsView.swift").read_text()
picker = source[source.index("class SwitcherAppearancePicker:"):source.index("class ScrollView:")]
layout = source[source.index("    private func layoutParentViews("):source.index("    func centerRows(")]
layout = layout.replace("private func layoutParentViews", "func layoutParentViews")
output = Path(tempfile.mkdtemp(prefix="alt-tab-appearance-"))
header = r'''
import Cocoa

enum AppearanceStylePreference: CaseIterable {
    case thumbnails, appIcons, titles
    var localizedString: String {
        switch self {
        case .thumbnails: return "Thumbnails"
        case .appIcons: return "App Icons"
        case .titles: return "Titles"
        }
    }
}
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
'''
layout_header = r'''
enum Appearance {
    static let windowPadding = CGFloat(12)
    static let intraCellPadding = CGFloat(6)
}
enum Preferences {
    static var appearanceStyle = AppearanceStylePreference.thumbnails
}
enum App { static let shared = NSApplication.shared }
enum ThumbnailsPanel { static func maxThumbnailsHeight() -> CGFloat { 500 } }
class ThumbnailsView: NSView {
    static var thumbnailsWidth = CGFloat(0)
    static var thumbnailsHeight = CGFloat(0)
    let scrollView = NSScrollView()
    let appearancePicker = SwitcherAppearancePicker()
    init() {
        super.init(frame: .zero)
        scrollView.documentView = NSView()
        addSubview(scrollView)
        addSubview(appearancePicker)
    }
    required init?(coder: NSCoder) { fatalError() }
'''
checks = r'''
let app = NSApplication.shared
let picker = SwitcherAppearancePicker()
picker.frame = NSRect(x: 10, y: 10, width: SwitcherAppearancePicker.buttonSize,
    height: SwitcherAppearancePicker.height)
let buttons = picker.subviews.compactMap { $0 as? SwitcherAppearanceButton }
precondition(buttons.count == 3)
var selections = [AppearanceStylePreference]()
picker.onSelect = { selections.append($0) }
for (index, style) in AppearanceStylePreference.allCases.enumerated() {
    buttons[index].performClick(nil)
    precondition(selections.last == style)
    precondition(buttons.filter { $0.state == .on }.count == 1)
    precondition(buttons[index].state == .on)
    precondition(buttons[index].toolTip == style.localizedString)
    precondition(buttons[index].accessibilityLabel() == style.localizedString)
    precondition(buttons[index].refusesFirstResponder)
    precondition(picker.bounds.contains(buttons[index].frame))
    // Clicking the active style must leave it selected.
    buttons[index].performClick(nil)
    precondition(buttons[index].state == .on)
}
picker.updateSelection(.thumbnails)
precondition(buttons[0].state == .on && buttons[1].state == .off && buttons[2].state == .off)

let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 122),
    styleMask: .borderless, backing: .buffered, defer: false)
let content = window.contentView!
content.addSubview(picker)
for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    let appearance = NSAppearance(named: appearanceName)!
    window.appearance = appearance
    for (index, style) in AppearanceStylePreference.allCases.enumerated() {
        picker.updateSelection(style)
        appearance.performAsCurrentDrawingAppearance {
            let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
            content.cacheDisplay(in: content.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])!
            let path = URL(fileURLWithPath: CommandLine.arguments[1])
                .appendingPathComponent("picker-\(name)-\(index).png")
            try! png.write(to: path)
        }
    }
}
print("PASS: style actions, exclusive selection, repeat clicks, tooltips, accessibility, and button layout")

let layoutView = ThumbnailsView()
for style in AppearanceStylePreference.allCases {
    Preferences.appearanceStyle = style
    for size in [NSSize(width: 80, height: 36), NSSize(width: 600, height: 800)] {
        layoutView.layoutParentViews(size.width, 400, size.height, 16)
        precondition(layoutView.bounds.contains(layoutView.appearancePicker.frame))
        precondition(layoutView.scrollView.frame.minX >= layoutView.appearancePicker.frame.maxX + 12)
        precondition(layoutView.scrollView.frame.maxX <= layoutView.bounds.maxX)
        precondition(layoutView.scrollView.frame.width <= 400)
        precondition(layoutView.scrollView.frame.height <= 500)
        precondition(layoutView.scrollView.documentView!.frame.size == size)
    }
}
print("PASS: actual parent layout keeps the rail inside the panel and outside scrolling content in all three styles")
'''
swift_file = output / "main.swift"
swift_file.write_text(header + picker + layout_header + layout + "}\n" + checks)
subprocess.run(["xcrun", "swiftc", "-warnings-as-errors", str(swift_file),
                "-o", str(output / "check-picker")], check=True)
subprocess.run([str(output / "check-picker"), str(output)], check=True)
subprocess.run(["xcrun", "swiftc", "-frontend", "-parse",
                str(root / "src/ui/main-window/ThumbnailsView.swift"),
                str(root / "src/ui/preferences-window/tabs/appearance/AppearanceTab.swift")], check=True)
print(f"Previews: {output}")
