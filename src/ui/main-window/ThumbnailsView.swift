import Cocoa

class ThumbnailsView: NSVisualEffectView {
    let scrollView = ScrollView()
    private let appearancePicker = SwitcherAppearancePicker()
    static var recycledViews = [ThumbnailView]()
    var rows = [[ThumbnailView]]()
    static var thumbnailsWidth = CGFloat(0.0)
    static var thumbnailsHeight = CGFloat(0.0)

    convenience init() {
        self.init(frame: .zero)
        material = Appearance.material
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        updateRoundedCorners(Appearance.windowCornerRadius)
        addSubview(scrollView)
        addSubview(appearancePicker)
        appearancePicker.onSelect = { [weak self] style in
            guard let self, style != Preferences.appearanceStyle else { return }
            WindowLabels.cancelEditingIfNeeded()
            Preferences.set("appearanceStyle", style.indexAsString)
            self.reset()
            AppearanceTab.toggleCustomizeStyleButton()
            App.app.refreshOpenUi(Windows.list, .refreshUiAfterExternalEvent)
        }
        // TODO: think about this optimization more
        (1...20).forEach { _ in ThumbnailsView.recycledViews.append(ThumbnailView()) }
    }

    func reset() {
        // it would be nicer to remove this whole "reset" logic, and instead update each component to check Appearance properties before showing
        // Maybe in some Appkit willDraw() function that triggers before drawing it
        NSScreen.updatePreferred()
        Appearance.update()
        material = Appearance.material
        for i in 0..<ThumbnailsView.recycledViews.count {
            ThumbnailsView.recycledViews[i] = ThumbnailView()
        }
        updateRoundedCorners(Appearance.windowCornerRadius)
        appearancePicker.updateSelection(Preferences.appearanceStyle)
    }

    static func highlight(_ indexInRecycledViews: Int) {
        let view = recycledViews[indexInRecycledViews]
        view.indexInRecycledViews = indexInRecycledViews
        if view.frame != NSRect.zero {
            view.drawHighlight()
        }
    }

    /// using layer!.cornerRadius works but the corners are aliased; this custom approach gives smooth rounded corners
    /// see https://stackoverflow.com/a/29386935/2249756
    func updateRoundedCorners(_ cornerRadius: CGFloat) {
        if cornerRadius == 0 {
            maskImage = nil
        } else {
            let edgeLength = 2.0 * cornerRadius + 1.0
            let mask = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
                let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
                NSColor.black.set()
                bezierPath.fill()
                return true
            }
            mask.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
            mask.resizingMode = .stretch
            maskImage = mask
        }
    }

    func nextRow(_ direction: Direction, allowWrap: Bool = true) -> [ThumbnailView]? {
        let step = direction == .down ? 1 : -1
        if let currentRow = Windows.focusedWindow()?.rowIndex {
            var nextRow = currentRow + step
            if nextRow >= rows.count {
                if allowWrap {
                    nextRow = nextRow % rows.count
                } else {
                    return nil
                }
            } else if nextRow < 0 {
                if allowWrap {
                    nextRow = rows.count + nextRow
                } else {
                    return nil
                }
            }
            if ((step > 0 && nextRow < currentRow) || (step < 0 && nextRow > currentRow)) &&
                   (ATShortcut.lastEventIsARepeat || KeyRepeatTimer.timer?.isValid ?? false) {
                return nil
            }
            return rows[nextRow]
        }
        return nil
    }

    func navigateUpOrDown(_ direction: Direction, allowWrap: Bool = true) {
        let focusedViewFrame = ThumbnailsView.recycledViews[Windows.focusedWindowIndex].frame
        let originCenter = NSMidX(focusedViewFrame)
        if let targetRow = nextRow(direction, allowWrap: allowWrap) {
            let leftSide = originCenter < NSMidX(scrollView.documentView!.bounds)
            let leadingSide = App.shared.userInterfaceLayoutDirection == .leftToRight ? leftSide : !leftSide
            let iterable = leadingSide ? targetRow : targetRow.reversed()
            let targetView = iterable.first {
                if App.shared.userInterfaceLayoutDirection == .leftToRight {
                    return leadingSide ? NSMaxX($0.frame) > originCenter : NSMinX($0.frame) < originCenter
                }
                return leadingSide ? NSMinX($0.frame) < originCenter : NSMaxX($0.frame) > originCenter
            } ?? iterable.last!
            let targetIndex = ThumbnailsView.recycledViews.firstIndex(of: targetView)!
            Windows.updateFocusedAndHoveredWindowIndex(targetIndex)
        }
    }

    func updateItemsAndLayout() {
        let widthMax = (ThumbnailsPanel.maxThumbnailsWidth() - SwitcherAppearancePicker.reservedWidth).rounded()
        if let (maxX, maxY, labelHeight) = layoutThumbnailViews(widthMax) {
            layoutParentViews(maxX, widthMax, maxY, labelHeight)
            if Preferences.alignThumbnails == .center {
                centerRows(maxX)
            }
            for row in rows {
                for (j, view) in row.enumerated() {
                    view.numberOfViewsInRow = row.count
                    view.isFirstInRow = j == 0
                    view.isLastInRow = j == row.count - 1
                    view.indexInRow = j
                }
            }
            highlightStartView()
        }
    }

    private func layoutThumbnailViews(_ widthMax: CGFloat) -> (CGFloat, CGFloat, CGFloat)? {
        let labelHeight = ThumbnailsView.recycledViews.first!.label.cell!.cellSize.height
        let height = ThumbnailView.height(labelHeight)
        let isLeftToRight = App.shared.userInterfaceLayoutDirection == .leftToRight
        let startingX = isLeftToRight ? Appearance.interCellPadding : widthMax - Appearance.interCellPadding
        var currentX = startingX
        var currentY = Appearance.interCellPadding
        var maxX = CGFloat(0)
        var maxY = currentY + height + Appearance.interCellPadding
        var newViews = [ThumbnailView]()
        rows.removeAll(keepingCapacity: true)
        rows.append([ThumbnailView]())
        for (index, window) in Windows.list.enumerated() {
            guard App.app.appIsBeingUsed else { return nil }
            guard window.shouldShowTheUser else { continue }
            let view = ThumbnailsView.recycledViews[index]
            view.updateRecycledCellWithNewContent(window, index, height)
            let width = view.frame.size.width
            let projectedX = projectedWidth(currentX, width).rounded(.down)
            if needNewLine(projectedX, widthMax) {
                currentX = startingX
                currentY = (currentY + height + Appearance.interCellPadding).rounded(.down)
                view.frame.origin = CGPoint(x: localizedCurrentX(currentX, width), y: currentY)
                currentX = projectedWidth(currentX, width).rounded(.down)
                maxY = max(currentY + height + Appearance.interCellPadding, maxY)
                rows.append([ThumbnailView]())
            } else {
                view.frame.origin = CGPoint(x: localizedCurrentX(currentX, width), y: currentY)
                currentX = projectedX
                maxX = max(isLeftToRight ? currentX : widthMax - currentX, maxX)
            }
            rows[rows.count - 1].append(view)
            newViews.append(view)
            window.rowIndex = rows.count - 1
        }
        scrollView.documentView!.subviews = newViews
        return (maxX, maxY, labelHeight)
    }

    private func needNewLine(_ projectedX: CGFloat, _ widthMax: CGFloat) -> Bool {
        if App.shared.userInterfaceLayoutDirection == .leftToRight {
            return projectedX > widthMax
        }
        return projectedX < 0
    }

    private func projectedWidth(_ currentX: CGFloat, _ width: CGFloat) -> CGFloat {
        if App.shared.userInterfaceLayoutDirection == .leftToRight {
            return currentX + width + Appearance.interCellPadding
        }
        return currentX - width - Appearance.interCellPadding
    }

    private func localizedCurrentX(_ currentX: CGFloat, _ width: CGFloat) -> CGFloat {
        App.shared.userInterfaceLayoutDirection == .leftToRight ? currentX : currentX - width
    }

    private func layoutParentViews(_ maxX: CGFloat, _ widthMax: CGFloat, _ maxY: CGFloat, _ labelHeight: CGFloat) {
        let heightMax = ThumbnailsPanel.maxThumbnailsHeight()
        ThumbnailsView.thumbnailsWidth = min(maxX, widthMax)
        ThumbnailsView.thumbnailsHeight = min(maxY, heightMax)
        let frameWidth = ThumbnailsView.thumbnailsWidth + Appearance.windowPadding * 2 + SwitcherAppearancePicker.reservedWidth
        var frameHeight = ThumbnailsView.thumbnailsHeight + Appearance.windowPadding * 2
        let originX = Appearance.windowPadding + SwitcherAppearancePicker.reservedWidth
        var originY = Appearance.windowPadding
        if Preferences.appearanceStyle == .appIcons {
            // If there is title under the icon on the last line, the height of the title needs to be subtracted.
            frameHeight = frameHeight - Appearance.intraCellPadding - labelHeight
            originY = originY - Appearance.intraCellPadding - labelHeight
        }
        let minimumHeight = SwitcherAppearancePicker.height + Appearance.windowPadding * 2
        if frameHeight < minimumHeight {
            originY += (minimumHeight - frameHeight) / 2
            frameHeight = minimumHeight
        }
        frame.size = NSSize(width: frameWidth, height: frameHeight)
        appearancePicker.frame = NSRect(x: Appearance.windowPadding,
            y: (frameHeight - SwitcherAppearancePicker.height) / 2,
            width: SwitcherAppearancePicker.buttonSize, height: SwitcherAppearancePicker.height)
        appearancePicker.updateSelection(Preferences.appearanceStyle)
        scrollView.frame.size = NSSize(width: min(maxX, widthMax), height: min(maxY, heightMax))
        scrollView.frame.origin = CGPoint(x: originX, y: originY)
        scrollView.contentView.frame.size = scrollView.frame.size
        if App.shared.userInterfaceLayoutDirection == .rightToLeft {
            let croppedWidth = widthMax - maxX
            scrollView.documentView!.subviews.forEach { $0.frame.origin.x -= croppedWidth }
        }
        scrollView.documentView!.frame.size = NSSize(width: maxX, height: maxY)
        if let existingTrackingArea = scrollView.trackingAreas.first {
            scrollView.removeTrackingArea(existingTrackingArea)
        }
        scrollView.addTrackingArea(NSTrackingArea(rect: scrollView.bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: scrollView, userInfo: nil))
    }

    func centerRows(_ maxX: CGFloat) {
        var rowStartIndex = 0
        var rowWidth = Appearance.interCellPadding
        var rowY = Appearance.interCellPadding
        for (index, window) in Windows.list.enumerated() {
            guard App.app.appIsBeingUsed else { return }
            guard window.shouldShowTheUser else { continue }
            let view = ThumbnailsView.recycledViews[index]
            if view.frame.origin.y == rowY {
                rowWidth += view.frame.size.width + Appearance.interCellPadding
            } else {
                shiftRow(maxX, rowWidth, rowStartIndex, index)
                rowStartIndex = index
                rowWidth = Appearance.interCellPadding + view.frame.size.width + Appearance.interCellPadding
                rowY = view.frame.origin.y
            }
        }
        shiftRow(maxX, rowWidth, rowStartIndex, Windows.list.count)
    }

    private func highlightStartView() {
        ThumbnailsView.highlight(Windows.focusedWindowIndex)
        if let hoveredWindowIndex = Windows.hoveredWindowIndex {
            ThumbnailsView.highlight(hoveredWindowIndex)
        }
    }

    private func shiftRow(_ maxX: CGFloat, _ rowWidth: CGFloat, _ rowStartIndex: Int, _ index: Int) {
        let offset = ((maxX - rowWidth) / 2).rounded()
        if offset > 0 {
            for i in rowStartIndex..<index {
                ThumbnailsView.recycledViews[i].frame.origin.x += App.shared.userInterfaceLayoutDirection == .leftToRight ? offset : -offset
            }
        }
    }
}

/// A fixed rail, separate from the scrolling window entries.
class SwitcherAppearancePicker: FlippedView {
    static let buttonSize = CGFloat(30)
    static let spacing = CGFloat(6)
    static let reservedWidth = buttonSize + 12
    static let height = buttonSize * 3 + spacing * 2
    var onSelect: ((AppearanceStylePreference) -> Void)?
    private var buttons = [SwitcherAppearanceButton]()

    init() {
        super.init(frame: .zero)
        setAccessibilityLabel(NSLocalizedString("Appearance", comment: ""))
        for (index, style) in AppearanceStylePreference.allCases.enumerated() {
            let button = SwitcherAppearanceButton(style)
            button.frame = NSRect(x: 0, y: CGFloat(index) * (Self.buttonSize + Self.spacing),
                width: Self.buttonSize, height: Self.buttonSize)
            button.target = self
            button.action = #selector(selectStyle)
            addSubview(button)
            buttons.append(button)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    func updateSelection(_ selectedStyle: AppearanceStylePreference) {
        for button in buttons {
            button.state = button.style == selectedStyle ? .on : .off
            button.needsDisplay = true
        }
    }

    @objc private func selectStyle(_ sender: SwitcherAppearanceButton) {
        updateSelection(sender.style)
        onSelect?(sender.style)
    }
}

class SwitcherAppearanceButton: NSButton {
    let style: AppearanceStylePreference
    private var isHovered = false

    init(_ style: AppearanceStylePreference) {
        self.style = style
        super.init(frame: .zero)
        title = ""
        toolTip = style.localizedString
        setAccessibilityLabel(style.localizedString)
        setButtonType(.toggle)
        isBordered = false
        refusesFirstResponder = true
        imagePosition = .imageOnly
        image = Self.makeIcon(style)
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if state == .on || isHovered || isHighlighted {
            let color = state == .on ? NSColor.selectedControlColor : NSColor.labelColor
            color.withAlphaComponent(isHighlighted ? 0.4 : state == .on ? 0.3 : 0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6).fill()
        }
        image?.draw(in: NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2,
            width: 18, height: 18), from: .zero, operation: .sourceOver, fraction: 1,
            respectFlipped: true, hints: nil)
    }

    private static func makeIcon(_ style: AppearanceStylePreference) -> NSImage {
        NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.4
            switch style {
            case .thumbnails:
                path.appendRoundedRect(NSRect(x: 1.5, y: 3, width: 15, height: 12), xRadius: 2, yRadius: 2)
                path.move(to: NSPoint(x: 2, y: 6.5))
                path.line(to: NSPoint(x: 16, y: 6.5))
                path.move(to: NSPoint(x: 4, y: 12))
                path.line(to: NSPoint(x: 7, y: 9))
                path.line(to: NSPoint(x: 10, y: 12))
                path.line(to: NSPoint(x: 13, y: 9))
            case .appIcons:
                for x in [CGFloat(2), 10] {
                    for y in [CGFloat(2), 10] {
                        path.appendRoundedRect(NSRect(x: x, y: y, width: 6, height: 6), xRadius: 1.5, yRadius: 1.5)
                    }
                }
            case .titles:
                for y in [CGFloat(4), 9, 14] {
                    path.appendRoundedRect(NSRect(x: 1.5, y: y - 1, width: 2, height: 2), xRadius: 0.5, yRadius: 0.5)
                    path.move(to: NSPoint(x: 6, y: y))
                    path.line(to: NSPoint(x: 16, y: y))
                }
            }
            path.stroke()
            return true
        }
    }
}

class ScrollView: NSScrollView {
    // overriding scrollWheel() turns this false; we force it to be true to enable responsive scrolling
    override class var isCompatibleWithResponsiveScrolling: Bool { true }

    var isCurrentlyScrolling = false
    var previousTarget: ThumbnailView?

    convenience init() {
        self.init(frame: .zero)
        documentView = FlippedView(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        verticalScrollElasticity = .none
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        horizontalScrollElasticity = .none
        usesPredominantAxisScrolling = true
        observeScrollingEvents()
    }

    private func observeScrollingEvents() {
        NotificationCenter.default.addObserver(self, selector: #selector(scrollingStarted), name: NSScrollView.willStartLiveScrollNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(scrollingEnded), name: NSScrollView.didEndLiveScrollNotification, object: nil)
    }

    @objc private func scrollingStarted() {
        isCurrentlyScrolling = true
    }

    @objc private func scrollingEnded() {
        isCurrentlyScrolling = false
    }

    private func resetHoveredWindow() {
        if let oldIndex = Windows.hoveredWindowIndex {
            Windows.hoveredWindowIndex = nil
            ThumbnailsView.highlight(oldIndex)
            ThumbnailsView.recycledViews[oldIndex].showOrHideWindowControls(false)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        // disable mouse hover during scrolling as it creates jank during elastic bounces at the start/end of the scrollview
        if isCurrentlyScrolling { return }
        if let hit = hitTest(App.app.thumbnailsPanel.mouseLocationOutsideOfEventStream) {
            var target: NSView? = hit
            while !(target is ThumbnailView) && target != nil {
                target = target!.superview
            }
            if let target = target as? ThumbnailView {
                if previousTarget != target {
                    previousTarget?.showOrHideWindowControls(false)
                    previousTarget = target
                }
                target.mouseMoved()
            } else {
                if !checkIfWithinInterPadding() {
                    resetHoveredWindow()
                }
            }
        } else {
            resetHoveredWindow()
        }
    }

    override func mouseExited(with event: NSEvent) {
        resetHoveredWindow()
    }

    /// Checks whether the mouse pointer is within the padding area around a thumbnail.
    ///
    /// This is used to avoid gaps between thumbnail views where the mouse pointer might not be detected.
    ///
    /// @return `true` if the mouse pointer is within the padding area around a thumbnail; `false` otherwise.
    private func checkIfWithinInterPadding() -> Bool {
        if Preferences.appearanceStyle == .appIcons {
            let mouseLocation = App.app.thumbnailsPanel.mouseLocationOutsideOfEventStream
            let mouseRect = NSRect(x: mouseLocation.x - Appearance.interCellPadding,
                y: mouseLocation.y - Appearance.interCellPadding,
                width: 2 * Appearance.interCellPadding,
                height: 2 * Appearance.interCellPadding)
            if let hoveredWindowIndex = Windows.hoveredWindowIndex {
                let thumbnail = ThumbnailsView.recycledViews[hoveredWindowIndex]
                let mouseRectInView = thumbnail.convert(mouseRect, from: nil)
                if thumbnail.bounds.intersects(mouseRectInView) {
                    return true
                }
            }
        }
        return false
    }

    /// holding shift and using the scrolling wheel will generate a horizontal movement
    /// shift can be part of shortcuts so we force shift scrolls to be vertical
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) && event.scrollingDeltaY == 0 {
            let cgEvent = event.cgEvent!
            cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: cgEvent.getDoubleValueField(.scrollWheelEventDeltaAxis2))
            cgEvent.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: 0)
            super.scrollWheel(with: NSEvent(cgEvent: cgEvent)!)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

enum Direction {
    case right
    case left
    case leading
    case trailing
    case up
    case down

    func step() -> Int {
        if self == .left {
            return App.shared.userInterfaceLayoutDirection == .leftToRight ? -1 : 1
        } else if self == .right {
            return App.shared.userInterfaceLayoutDirection == .leftToRight ? 1 : -1
        }
        return self == .leading ? 1 : -1
    }
}
