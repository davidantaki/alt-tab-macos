import Cocoa
import Carbon.HIToolbox.Events

class ThumbnailView: FlippedView {
    static let noOpenWindowToolTip = NSLocalizedString("App is running but has no open window", comment: "")
    var window_: Window?
    var thumbnail = LightImageView()
    var windowlessIcon = LightImageView()
    let thumbnailContainer = FlippedView()
    var appIcon = LightImageView()
    var label = ThumbnailTitleView(shadow: ThumbnailView.makeShadow(Appearance.titleShadowColor), font: Appearance.font)
    var fullscreenIcon = ThumbnailFontIconView(symbol: .circledPlusSign, tooltip: NSLocalizedString("Window is fullscreen", comment: ""))
    var minimizedIcon = ThumbnailFontIconView(symbol: .circledMinusSign, tooltip: NSLocalizedString("Window is minimized", comment: ""))
    var hiddenIcon = ThumbnailFontIconView(symbol: .circledSlashSign, tooltip: NSLocalizedString("App is hidden", comment: ""))
    var spaceIcon = ThumbnailFontIconView(symbol: .circledNumber0)
    var dockLabelIcon = ThumbnailFilledFontIconView(
        ThumbnailFontIconView(symbol: .filledCircledNumber0, size: dockLabelLabelSize(), color: NSColor(srgbRed: 1, green: 0.30, blue: 0.25, alpha: 1), shadow: nil),
        backgroundColor: NSColor.white, size: dockLabelLabelSize())
    var quitIcon = TrafficLightButton(.quit, NSLocalizedString("Quit app", comment: ""))
    var closeIcon = TrafficLightButton(.close, NSLocalizedString("Close window", comment: ""))
    var minimizeIcon = TrafficLightButton(.miniaturize, NSLocalizedString("Minimize/Deminimize window", comment: ""))
    var maximizeIcon = TrafficLightButton(.fullscreen, NSLocalizedString("Fullscreen/Defullscreen window", comment: ""))
    var editLabelButton = EditLabelButton()
    var labelEditor = ThumbnailLabelEditor()
    var windowlessAppIndicator = WindowlessAppIndicator(tooltip: ThumbnailView.noOpenWindowToolTip)

    let hStackView = FlippedView()
    let vStackView = FlippedView()
    var mouseUpCallback: (() -> Void)!
    var mouseMovedCallback: (() -> Void)!
    var dragAndDropTimer: Timer?
    var indexInRecycledViews: Int!
    var isShowingWindowControls = false
    var isEditingLabel = false

    var isFirstInRow = false
    var isLastInRow = false
    var indexInRow = 0
    var numberOfViewsInRow = 0

    var windowControlIcons: [TrafficLightButton] { [quitIcon, closeIcon, minimizeIcon, maximizeIcon] }
    var windowIndicatorIcons: [ThumbnailFontIconView] { [hiddenIcon, fullscreenIcon, minimizedIcon, spaceIcon] }

    var receivedMouseDown = false

    // for VoiceOver cursor
    override var canBecomeKeyView: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func isAccessibilityElement() -> Bool { true }

    override func wantsPeriodicDraggingUpdates() -> Bool { false }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        mouseMovedCallback()
        setDraggingTimer()
        return .link
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        setDraggingTimer()
        return .link
    }

    private func setDraggingTimer() {
        dragAndDropTimer?.invalidate()
        dragAndDropTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false, block: { _ in
            // the user can tab to focus the next thumbnail, while still dragging. We don't want to perform drag then
            if Windows.focusedWindowIndex == Windows.hoveredWindowIndex {
                self.mouseUpCallback()
            }
        })
        dragAndDropTimer?.tolerance = 0.2
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragAndDropTimer?.invalidate()
        dragAndDropTimer = nil
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dragAndDropTimer?.invalidate()
        dragAndDropTimer = nil
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as! [URL]
        let appUrl = window_!.application.bundleURL!
        let open = try? NSWorkspace.shared.open(urls, withApplicationAt: appUrl, options: [], configuration: [:])
        App.app.hideUi()
        return open != nil
    }

    override func mouseDown(with event: NSEvent) {
        // Don't treat clicks on the edit-label control as "select this window"
        if isEventOnEditLabelButton(event) { return }
        receivedMouseDown = true
    }

    override func mouseUp(with event: NSEvent) {
        if isEventOnEditLabelButton(event) {
            receivedMouseDown = false
            return
        }
        if receivedMouseDown {
            if bounds.contains(convert(event.locationInWindow, from: nil)) {
                mouseUpCallback()
            }
            receivedMouseDown = false
        }
    }

    private func isEventOnEditLabelButton(_ event: NSEvent) -> Bool {
        let locInWindow = event.locationInWindow
        let loc = convert(locInWindow, from: nil)
        guard let hit = hitTest(loc) else { return false }
        var view: NSView? = hit
        while let current = view {
            if current === editLabelButton { return true }
            if current === self { break }
            view = current.superview
        }
        // Fallback: frame contains point (hit testing can miss frame-based views in panels)
        let locInButton = editLabelButton.convert(locInWindow, from: nil)
        return !editLabelButton.isHidden && editLabelButton.bounds.contains(locInButton)
    }

    override func otherMouseUp(with event: NSEvent) {
        // middle-click
        if event.buttonNumber == 2 {
            if let window_ {
                if window_.isWindowlessApp {
                    window_.application.quit()
                } else {
                    window_.close()
                }
            }
        }
    }

    func mouseMoved() {
        showOrHideWindowControls(true)
        // Keep edit-button hover in sync even if tracking areas miss events in the panel
        let locInButton = editLabelButton.convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        editLabelButton.setHover(!editLabelButton.isHidden && editLabelButton.bounds.contains(locInButton))
        mouseMovedCallback()
    }

    convenience init() {
        self.init(frame: .zero)
        setupView()
        observeDragAndDrop()
    }

    func updateRecycledCellWithNewContent(_ element: Window, _ index: Int, _ newHeight: CGFloat) {
        if isEditingLabel, window_ !== element {
            cancelLabelEditing()
        }
        window_ = element
        updateValues(element, index, newHeight)
        updateSizes(newHeight)
        updatePositions(newHeight)
        if !isEditingLabel {
            label.toolTip = label.cell!.cellSize.width >= label.frame.size.width ? label.stringValue : nil
        }
    }

    func drawHighlight() {
        let isFocused = indexInRecycledViews == Windows.focusedWindowIndex
        let isHovered = indexInRecycledViews == Windows.hoveredWindowIndex
        setBackground(isFocused: isFocused, isHovered: isHovered)
        setBorder(isFocused: isFocused, isHovered: isHovered)
        setShadow(isFocused: isFocused, isHovered: isHovered)
        if Preferences.appearanceStyle == .appIcons {
            if isEditingLabel {
                label.isHidden = true
                labelEditor.isHidden = false
            } else {
                label.isHidden = !(isFocused || isHovered)
                updateAppIconsLabel(isFocused: isFocused, isHovered: isHovered)
            }
        }
        updateEditLabelButtonVisibility()
    }

    func showOrHideWindowControls(_ shouldShowWindowControls: Bool) {
        // Keep controls visible while the user is typing a custom label.
        let showRequested = shouldShowWindowControls || isEditingLabel
        let shouldShowTrafficLights = showRequested && !Preferences.hideColoredCircles && !Appearance.hideThumbnails
        if Preferences.appearanceStyle == .thumbnails {
            isShowingWindowControls = shouldShowTrafficLights
            for icon in windowControlIcons {
                icon.isHidden = !shouldShowTrafficLights
                    || (icon.type == .quit && !(window_?.application.canBeQuit() ?? true))
                    || (icon.type == .close && !(window_?.canBeClosed() ?? true))
                    || ((icon.type == .miniaturize || icon.type == .fullscreen) && !(window_?.canBeMinDeminOrFullscreened() ?? true))
                // Force the icons to redraw; otherwise after clicking the fullscreen button,
                // it will still appear to be in fullscreen mode.
                icon.display()
            }
        }
        updateEditLabelButtonVisibility()
    }

    /// Always show the ✎ button on each row (except while editing that row).
    private func updateEditLabelButtonVisibility() {
        editLabelButton.isHidden = window_ == nil || isEditingLabel
    }

    func updateDockLabelIcon(_ dockLabel: String?) {
        assignIfDifferent(&dockLabelIcon.isHidden, dockLabel == nil || Preferences.hideAppBadges || Appearance.iconSize == 0)
        if !dockLabelIcon.isHidden, let dockLabel {
            let view = dockLabelIcon.subviews[1] as! ThumbnailFontIconView
            let dockLabelInt = Int(dockLabel)
            if dockLabelInt == nil || dockLabelInt! > 30 {
                view.setFilledStar()
            } else {
                view.setNumber(dockLabelInt!, true)
            }
            view.setAccessibilityLabel(getAccessibilityTextForBadge(dockLabel))
        }
    }

    private func setupView() {
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityChildren([])
        wantsLayer = true
        layer!.masksToBounds = false // without this, label will be clipped in app-icons style since its larger than its parentView
        setupSharedSubiews()
        setupStyleSpecificSubviews()
    }

    private func setupSharedSubiews() {
        let shadow = ThumbnailView.makeShadow(Appearance.imageShadowColor)
        thumbnailContainer.wantsLayer = true
        thumbnailContainer.layer!.masksToBounds = false // let thumbnail shadows show
        thumbnail.shadow = shadow
        windowlessIcon.shadow = shadow
        appIcon.shadow = shadow
        windowlessIcon.translatesAutoresizingMaskIntoConstraints = false
        windowlessIcon.toolTip = ThumbnailView.noOpenWindowToolTip
        appIcon.translatesAutoresizingMaskIntoConstraints = false
        appIcon.setSubviewAbove(dockLabelIcon)
        label.fixHeight()
        setupLabelEditor()
        setupEditLabelButton()
        vStackView.wantsLayer = true
        vStackView.layer!.backgroundColor = .clear
        vStackView.layer!.borderColor = .clear
        vStackView.layer!.cornerRadius = Appearance.cellCornerRadius
        vStackView.layer!.borderWidth = CGFloat(1)
        setSubviews([vStackView])
        vStackView.setSubviews([hStackView])
        hStackView.setSubviews([appIcon])
    }

    private func setupEditLabelButton() {
        editLabelButton.onClick = { [weak self] in
            self?.beginLabelEditing()
        }
        // Visible by default once a window is bound; see updateEditLabelButtonVisibility()
        editLabelButton.isHidden = false
        // Frame-based layout (same as the rest of the switcher); do not leave Auto Layout on.
        editLabelButton.translatesAutoresizingMaskIntoConstraints = true
    }

    private func setupLabelEditor() {
        labelEditor.isHidden = true
        labelEditor.target = self
        labelEditor.action = #selector(commitLabelEditing)
        labelEditor.onEscape = { [weak self] in
            self?.cancelLabelEditing()
        }
    }

    private func setupStyleSpecificSubviews() {
        if Preferences.appearanceStyle == .appIcons {
            addSubviews([label, labelEditor])
            hStackView.setSubviewAbove(windowlessAppIndicator)
            // Top-right of the icon cell
            vStackView.setSubviewAbove(editLabelButton)
            label.alignment = .center
            label.isHidden = true
        } else if Preferences.appearanceStyle == .thumbnails {
            vStackView.addSubviews([thumbnailContainer])
            thumbnailContainer.setSubviews([thumbnail, windowlessIcon])
            thumbnailContainer.setSubviewAbove(windowlessAppIndicator)
            for icon in windowControlIcons {
                thumbnailContainer.setSubviewAbove(icon)
                icon.isHidden = true
            }
            // Title row: label + status icons + edit button on the far right
            hStackView.addSubviews([label] + windowIndicatorIcons + [editLabelButton])
            hStackView.addSubviews([labelEditor])
        } else {
            // Titles style: edit button always on the far right of the row
            hStackView.setSubviewAbove(windowlessAppIndicator)
            hStackView.addSubviews([label] + windowIndicatorIcons + [editLabelButton])
            hStackView.addSubviews([labelEditor])
        }
    }

    private func getBackgroundColor(isFocused: Bool, isHovered: Bool) -> NSColor {
        if isFocused {
            return Appearance.highlightFocusedBackgroundColor
        }
        if isHovered {
            return Appearance.highlightHoveredBackgroundColor
        }
        return NSColor.clear
    }

    private func setBackground(isFocused: Bool, isHovered: Bool) {
        vStackView.layer!.backgroundColor = getBackgroundColor(isFocused: isFocused, isHovered: isHovered).cgColor
    }

    private func setBorder(isFocused: Bool, isHovered: Bool) {
        if isFocused {
            vStackView.layer!.borderColor = Appearance.highlightFocusedBorderColor.cgColor
            vStackView.layer!.borderWidth = Appearance.highlightBorderWidth
        } else if isHovered {
            vStackView.layer!.borderColor = Appearance.highlightHoveredBorderColor.cgColor
            vStackView.layer!.borderWidth = Appearance.highlightBorderWidth
        } else {
            vStackView.layer!.borderColor = NSColor.clear.cgColor
            vStackView.layer!.borderWidth = 0
        }
    }

    private func setShadow(isFocused: Bool, isHovered: Bool) {
        if (isFocused || isHovered) && Appearance.highlightBorderShadowColor != .clear {
            vStackView.layer!.shadowColor = Appearance.highlightBorderShadowColor.cgColor
            vStackView.layer!.shadowOpacity = 0.25
            vStackView.layer!.shadowOffset = .zero
            vStackView.layer!.shadowRadius = 1
        }
    }

    private func updateAppIconsLabel(isFocused: Bool, isHovered: Bool) {
        let focusedView = ThumbnailsView.recycledViews[Windows.focusedWindowIndex]
        var hoveredView: ThumbnailView? = nil
        if Windows.hoveredWindowIndex != nil {
            hoveredView = ThumbnailsView.recycledViews[Windows.hoveredWindowIndex!]
        }
        if isFocused || (!isFocused && !isHovered) {
            hoveredView?.label.isHidden = true
            focusedView.label.isHidden = false
            updateAppIconsLabelFrame(focusedView)
        } else if isHovered {
            hoveredView?.label.isHidden = false
            focusedView.label.isHidden = true
            if let hoveredView {
                updateAppIconsLabelFrame(hoveredView)
            }
        }
    }

    private func getMaxAllowedLabelWidth(_ view: ThumbnailView) -> CGFloat {
        let viewWidth = view.frame.width
        let maxAllowedWidth = min(viewWidth * 2, ThumbnailsView.thumbnailsWidth)
        let availableLeftWidth = view.isFirstInRow ? 0 : CGFloat(view.indexInRow) * viewWidth
        let availableRightWidth = view.isLastInRow ? 0 : CGFloat(view.numberOfViewsInRow - 1 - view.indexInRow) * viewWidth
        let totalWidth = availableLeftWidth + availableRightWidth + viewWidth
        let maxLabelWidth = min(totalWidth, maxAllowedWidth)
        return maxLabelWidth
    }

    private func updateAppIconsLabelFrame(_ view: ThumbnailView) {
        let viewWidth = view.frame.width
        let labelWidth = view.label.cell!.cellSize.width
        let maxAllowedLabelWidth = getMaxAllowedLabelWidth(view)
        let effectiveLabelWidth = max(min(labelWidth, maxAllowedLabelWidth), viewWidth)
        var leftOffset = CGFloat(0)
        if view.isFirstInRow && view.isLastInRow {
            leftOffset = 0
        } else if view.isLastInRow {
            leftOffset = max(0, effectiveLabelWidth - viewWidth)
        } else if !view.isFirstInRow && !view.isLastInRow {
            let halfNeededOffset = max(0, (effectiveLabelWidth - viewWidth) / 2)
            let availableLeftWidth = view.isFirstInRow ? 0 : CGFloat(view.indexInRow) * viewWidth
            let availableRightWidth = view.isLastInRow ? 0 : CGFloat(view.numberOfViewsInRow - 1 - view.indexInRow) * viewWidth
            if availableLeftWidth >= halfNeededOffset && availableRightWidth >= halfNeededOffset {
                leftOffset = halfNeededOffset
            } else if availableLeftWidth <= halfNeededOffset && availableRightWidth <= halfNeededOffset {
                leftOffset = availableLeftWidth
            } else if availableRightWidth <= halfNeededOffset {
                leftOffset = min(effectiveLabelWidth - viewWidth - availableRightWidth, availableLeftWidth)
            } else if availableLeftWidth <= halfNeededOffset {
                leftOffset = availableLeftWidth
            }
        }
        let xPosition = -leftOffset
        let height = view.label.cell!.cellSize.height
        let yPosition = view.hStackView.frame.origin.y + view.hStackView.frame.height + Appearance.intraCellPadding * 2
        view.label.frame = NSRect(x: xPosition, y: yPosition, width: effectiveLabelWidth, height: height)
        view.label.setWidth(effectiveLabelWidth)
        view.label.toolTip = view.label.cell!.cellSize.width >= view.label.frame.size.width ? view.label.stringValue : nil
    }

    private func updateAppIcon(_ element: Window, _ title: String) {
        let appIconSize = ThumbnailView.iconSize()
        appIcon.updateWithResizedCopy(element.icon, appIconSize)
        appIcon.setAccessibilityLabel(title)
    }

    private func updateValues(_ element: Window, _ index: Int, _ newHeight: CGFloat) {
        assignIfDifferent(&thumbnail.isHidden, Appearance.hideThumbnails || element.isWindowlessApp)
        assignIfDifferent(&windowlessIcon.isHidden, !element.isWindowlessApp || Appearance.hideThumbnails)
        assignIfDifferent(&windowlessAppIndicator.isHidden, !element.isWindowlessApp)
        assignIfDifferent(&hiddenIcon.isHidden, !element.isHidden || Preferences.hideStatusIcons)
        assignIfDifferent(&fullscreenIcon.isHidden, !element.isFullscreen || Preferences.hideStatusIcons)
        assignIfDifferent(&minimizedIcon.isHidden, !element.isMinimized || Preferences.hideStatusIcons)
        assignIfDifferent(&spaceIcon.isHidden, element.isWindowlessApp || Spaces.isSingleSpace() || Preferences.hideSpaceNumberLabels || (
            Preferences.spacesToShow[App.app.shortcutIndex] == .visible && (
                NSScreen.screens.count < 2 || Preferences.screensToShow[App.app.shortcutIndex] == .showingAltTab
            )
        ))
        if !thumbnail.isHidden {
            if let screenshot = element.thumbnail {
                let thumbnailSize = ThumbnailView.thumbnailSize(screenshot, false)
                thumbnail.updateWithResizedCopy(screenshot, thumbnailSize)
            } else {
                // if no thumbnail, show appIcon instead
                let thumbnailSize = ThumbnailView.thumbnailSize(element.icon, true)
                thumbnail.updateWithResizedCopy(element.icon, thumbnailSize)
            }
            // for Accessibility > "speak items under the pointer"
            thumbnail.setAccessibilityLabel(element.title)
        }
        let title = getAppOrAndWindowTitle()
        if !isEditingLabel {
            let labelChanged = label.stringValue != title
            if labelChanged {
                label.stringValue = title
                setAccessibilityLabel(title)
            }
            // Tooltip when truncated (full string includes custom label + normal title)
            label.toolTip = label.cell!.cellSize.width >= label.frame.size.width ? label.stringValue : nil
        }
        label.updateTruncationModeIfNeeded()
        if !spaceIcon.isHidden {
            let spaceIndex = element.spaceIndexes.first
            if element.isOnAllSpaces || (spaceIndex != nil && spaceIndex! > 30) {
                spaceIcon.setStar()
                spaceIcon.toolTip = NSLocalizedString("Window is on every Space", comment: "")
            } else if let spaceIndex {
                spaceIcon.setNumber(spaceIndex, false)
                spaceIcon.toolTip = String(format: NSLocalizedString("Window is on Space %d", comment: ""), spaceIndex)
            }
        }
        updateAppIcon(element, title)
        updateDockLabelIcon(element.dockLabel)
        setAccessibilityHelp(getAccessibilityHelp(element.application.localizedName, element.dockLabel))
        if !windowlessIcon.isHidden {
            let windowlessIconSize = ThumbnailView.thumbnailSize(element.icon, true)
            windowlessIcon.updateWithResizedCopy(element.icon, windowlessIconSize)
        }
        windowControlIcons.forEach { $0.window_ = element }
        showOrHideWindowControls(isShowingWindowControls)
        updateEditLabelButtonVisibility()
        mouseUpCallback = { () -> Void in App.app.focusSelectedWindow(element) }
        mouseMovedCallback = { () -> Void in Windows.updateFocusedAndHoveredWindowIndex(index, true) }
    }

    private func updateSizes(_ newHeight: CGFloat) {
        setFrameWidthHeight(newHeight)
        if Preferences.appearanceStyle == .appIcons {
            vStackView.frame.size = NSSize(width: frame.width, height: appIcon.frame.height + Appearance.edgeInsetsSize * 2)
            hStackView.frame.size = NSSize(width: appIcon.frame.width, height: appIcon.frame.height)
        } else {
            vStackView.frame.size = NSSize(width: frame.width, height: frame.height)
            let rowHeight = max(appIcon.frame.height, label.cell!.cellSize.height, EditLabelButton.minHeight)
            hStackView.frame.size = NSSize(width: frame.width - Appearance.edgeInsetsSize * 2, height: rowHeight)
            let labelWidth = hStackView.frame.width - appIcon.frame.width - Appearance.appIconLabelSpacing - indicatorsSpace() - editLabelButtonSpace()
            label.setWidth(labelWidth)
        }
        if Preferences.appearanceStyle == .thumbnails {
            let content = !windowlessIcon.isHidden ? windowlessIcon : thumbnail
            thumbnailContainer.frame.size = NSSize(width: hStackView.frame.width, height: content.frame.height)
        }
    }

    private func updatePositions(_ newHeight: CGFloat) {
        hStackView.frame.origin = NSPoint(x: Appearance.edgeInsetsSize, y: Appearance.edgeInsetsSize)
        if Preferences.appearanceStyle != .appIcons {
            let ltr = App.shared.userInterfaceLayoutDirection == .leftToRight
            appIcon.frame.origin.x = ltr ? 0 : hStackView.frame.width - appIcon.frame.width
            let iconWidth = windowIndicatorIcons.first!.cell!.cellSize.width
            let editWidth = EditLabelButton.width
            // Full-height edit button on the far right of the row (past the space-number circle)
            editLabelButton.translatesAutoresizingMaskIntoConstraints = true
            editLabelButton.frame = NSRect(
                x: ltr ? hStackView.frame.width - editWidth : 0,
                y: 0,
                width: editWidth,
                height: hStackView.frame.height
            )
            editLabelButton.updateTrackingAreas()
            // Status icons (e.g. space number circle) sit just left of the edit button
            var indicatorSpace = CGFloat(0)
            for icon in windowIndicatorIcons {
                if !icon.isHidden {
                    indicatorSpace += iconWidth
                    icon.centerFrameInParent(y: true)
                    icon.frame.origin.x = ltr
                        ? hStackView.frame.width - editWidth - Appearance.appIconLabelSpacing - indicatorSpace
                        : editWidth + Appearance.appIconLabelSpacing + indicatorSpace - iconWidth
                }
            }
            let rightChrome = editLabelButtonSpace() + indicatorSpace
            let labelWidth = max(0, hStackView.frame.width - appIcon.frame.width - Appearance.appIconLabelSpacing - rightChrome)
            label.setWidth(labelWidth)
            label.frame.origin.x = ltr
                ? appIcon.frame.maxX + Appearance.appIconLabelSpacing
                : rightChrome
            label.frame.size.width = labelWidth
            label.centerFrameInParent(y: true)
        }
        if Preferences.appearanceStyle == .thumbnails {
            let content = !windowlessIcon.isHidden ? windowlessIcon : thumbnail
            thumbnailContainer.frame.origin = NSPoint(x: Appearance.edgeInsetsSize, y: hStackView.frame.maxY + Appearance.intraCellPadding)
            content.centerFrameInParent(x: true)
            var xOffset = CGFloat(3)
            var yOffset = CGFloat(2)
            for icon in windowControlIcons {
                icon.frame.origin = NSPoint(x: xOffset, y: yOffset)
                xOffset += TrafficLightButton.size + TrafficLightButton.spacing
                if xOffset + TrafficLightButton.size > thumbnailContainer.frame.width {
                    xOffset = 3 + Appearance.edgeInsetsSize
                    yOffset += TrafficLightButton.size + TrafficLightButton.spacing
                }
            }
        } else if Preferences.appearanceStyle == .appIcons {
            // Full-height strip on the right of the icon cell
            let editWidth = EditLabelButton.width
            editLabelButton.translatesAutoresizingMaskIntoConstraints = true
            editLabelButton.frame = NSRect(
                x: max(0, vStackView.frame.width - editWidth),
                y: 0,
                width: editWidth,
                height: vStackView.frame.height
            )
            editLabelButton.updateTrackingAreas()
        }
        if isEditingLabel {
            layoutLabelEditor()
        }
        if !windowlessAppIndicator.isHidden {
            if Preferences.appearanceStyle != .titles {
                windowlessAppIndicator.centerFrameInParent(x: true)
            } else {
                windowlessAppIndicator.frame.origin.x = ((appIcon.frame.width / 2) - (windowlessAppIndicator.frame.width / 2)).rounded()
                    + (App.shared.userInterfaceLayoutDirection == .leftToRight ? 0 : appIcon.frame.origin.x)
            }
            windowlessAppIndicator.frame.origin.y = windowlessAppIndicator.superview!.frame.height - windowlessAppIndicator.frame.height
        }
        // we set dockLabelIcon origin, without checking if .isHidden
        // This is because its updated async. We needed it positioned correctly always
        let iconSize = ThumbnailView.iconSize()
        dockLabelIcon.frame.origin.x = ((iconSize.width * 0.8) - (dockLabelIcon.fittingSize.width / 2)).rounded()
        dockLabelIcon.frame.origin.y = ((iconSize.height * 0.8) - (dockLabelIcon.fittingSize.height / 2)).rounded()
            - (Preferences.appearanceSize == .small ? 2 : 0)
    }

    private func indicatorsSpace() -> CGFloat {
        let iconWidth = windowIndicatorIcons.first!.cell!.cellSize.width
        return CGFloat(windowIndicatorIcons.filter { !$0.isHidden }.count) * iconWidth
    }

    /// Width reserved for the always-visible edit-label button (+ spacing).
    private func editLabelButtonSpace() -> CGFloat {
        if editLabelButton.isHidden { return 0 }
        return EditLabelButton.width + Appearance.appIconLabelSpacing
    }

    private func getAppOrAndWindowTitle() -> String {
        let normalTitle = normalAppOrWindowTitle()
        // Custom AltTab-only label appears to the left of the normal title.
        if let window_, let custom = WindowLabels.label(for: window_), !custom.isEmpty {
            if normalTitle.isEmpty {
                return custom
            }
            return "\(custom) · \(normalTitle)"
        }
        return normalTitle
    }

    private func normalAppOrWindowTitle() -> String {
        let appName = window_?.application.localizedName
        let windowTitle = window_?.title
        if Preferences.onlyShowApplications() || Preferences.showTitles == .appName {
            return appName ?? ""
        } else if Preferences.showTitles == .appNameAndWindowTitle {
            return [appName, windowTitle].compactMap { $0 }.joined(separator: " - ")
        }
        return windowTitle ?? ""
    }

    @objc func beginLabelEditing() {
        guard let window_, !isEditingLabel else { return }
        WindowLabels.beginEditing(self)
        isEditingLabel = true
        showOrHideWindowControls(true)
        label.isHidden = true
        labelEditor.isHidden = false
        labelEditor.stringValue = WindowLabels.label(for: window_) ?? ""
        labelEditor.placeholderString = WindowLabels.originalTitleDescription(for: window_)
        layoutLabelEditor()
        // Make sure the panel can take keyboard focus for typing
        App.app.thumbnailsPanel.makeKeyAndOrderFront(nil)
        App.app.thumbnailsPanel.makeFirstResponder(labelEditor)
    }

    @objc func commitLabelEditing() {
        guard isEditingLabel, let window_ else {
            cancelLabelEditing()
            return
        }
        WindowLabels.setLabel(labelEditor.stringValue, for: window_)
        finishLabelEditing(committed: true)
    }

    func cancelLabelEditing() {
        guard isEditingLabel else { return }
        finishLabelEditing(committed: false)
    }

    private func finishLabelEditing(committed: Bool) {
        isEditingLabel = false
        WindowLabels.endEditing(self)
        labelEditor.isHidden = true
        labelEditor.abortEditing()
        App.app.thumbnailsPanel.makeFirstResponder(nil)
        if Preferences.appearanceStyle == .appIcons {
            let isFocused = indexInRecycledViews == Windows.focusedWindowIndex
            let isHovered = indexInRecycledViews == Windows.hoveredWindowIndex
            label.isHidden = !(isFocused || isHovered)
        } else {
            label.isHidden = false
        }
        if committed {
            let title = getAppOrAndWindowTitle()
            label.stringValue = title
            setAccessibilityLabel(title)
            label.toolTip = label.cell!.cellSize.width >= label.frame.size.width ? label.stringValue : nil
        }
        showOrHideWindowControls(indexInRecycledViews == Windows.hoveredWindowIndex
            || indexInRecycledViews == Windows.focusedWindowIndex)
        // Re-layout title width if label length changed
        if Preferences.appearanceStyle != .appIcons {
            let labelWidth = hStackView.frame.width - appIcon.frame.width - Appearance.appIconLabelSpacing - indicatorsSpace()
            label.setWidth(labelWidth)
        }
    }

    private func layoutLabelEditor() {
        if Preferences.appearanceStyle == .appIcons {
            labelEditor.frame = label.frame
            labelEditor.font = label.font
        } else {
            labelEditor.frame = label.frame
            labelEditor.font = label.font
        }
        // Ensure a comfortable typing height
        let height = max(labelEditor.frame.height, (label.font?.pointSize ?? 12) + 8)
        labelEditor.frame.size.height = height
        labelEditor.centerFrameInParent(y: true)
    }

    private func setFrameWidthHeight(_ newHeight: CGFloat) {
        var contentWidth = CGFloat(0)
        if Preferences.appearanceStyle == .thumbnails {
            // Preferred to the width of the image, and the minimum width may be set to be large.
            contentWidth = (!windowlessIcon.isHidden ? windowlessIcon : thumbnail).frame.size.width
        } else if Preferences.appearanceStyle == .titles {
            contentWidth = ThumbnailView.maxThumbnailWidth() - Appearance.edgeInsetsSize * 2
        } else {
            contentWidth = Appearance.iconSize
        }
        let frameWidth = (contentWidth + Appearance.edgeInsetsSize * 2).rounded()
        let widthMin = ThumbnailView.minThumbnailWidth()
        let width = max(frameWidth, widthMin).rounded()
        assignIfDifferent(&frame.size.width, width)
        assignIfDifferent(&frame.size.height, newHeight)
    }

    private func getAccessibilityHelp(_ appName: String?, _ dockLabel: String?) -> String {
        [appName, dockLabel.map { getAccessibilityTextForBadge($0) }]
            .compactMap { $0 }
            .joined(separator: " - ")
    }

    private func getAccessibilityTextForBadge(_ dockLabel: String) -> String {
        if let dockLabelInt = Int(dockLabel) {
            return "Red badge with number \(dockLabelInt)"
        }
        return "Red badge"
    }

    private func observeDragAndDrop() {
        // NSImageView instances are registered to drag-and-drop by default
        thumbnail.unregisterDraggedTypes()
        appIcon.unregisterDraggedTypes()
        windowlessIcon.unregisterDraggedTypes()
        // we only handle URLs (i.e. not text, image, or other draggable things)
        registerForDraggedTypes([NSPasteboard.PasteboardType(kUTTypeURL as String)])
    }

    static func dockLabelLabelSize() -> CGFloat {
        let size = (ThumbnailView.iconSize().width * 0.43).rounded()
        // label should have a minimum size for readability
        return max(size, 13)
    }

    static func makeShadow(_ color: NSColor?) -> NSShadow? {
        if color == nil {
            return nil
        }
        let shadow = NSShadow()
        shadow.shadowColor = color
        shadow.shadowOffset = .zero
        shadow.shadowBlurRadius = 1
        return shadow
    }

    static func maxThumbnailWidth() -> CGFloat {
        return ThumbnailsPanel.maxThumbnailsWidth() * Appearance.windowMaxWidthInRow - Appearance.interCellPadding * 2
    }

    static func minThumbnailWidth() -> CGFloat {
        return ThumbnailsPanel.maxThumbnailsWidth() * Appearance.windowMinWidthInRow - Appearance.interCellPadding * 2
    }

    /// The maximum height that a thumbnail can be drawn
    /// maxThumbnailsHeight = maxThumbnailHeight * rowCount + interCellPadding * (rowCount - 1)
    /// maxThumbnailHeight = (maxThumbnailsHeight - interCellPadding * (rowCount - 1)) / rowCount
    static func maxThumbnailHeight() -> CGFloat {
        return ((ThumbnailsPanel.maxThumbnailsHeight() - Appearance.interCellPadding) / Appearance.rowsCount - Appearance.interCellPadding).rounded()
    }

    static func thumbnailSize(_ image: CGImage?, _ isWindowlessApp: Bool) -> NSSize {
        guard let image else { return NSSize(width: 0, height: 0) }
        let imageWidth = CGFloat(image.width)
        let imageHeight = CGFloat(image.height)
        let thumbnailHeightMax = ThumbnailView.maxThumbnailHeight()
            - Appearance.edgeInsetsSize * 2
            - Appearance.intraCellPadding
            - Appearance.iconSize
        let thumbnailWidthMax = ThumbnailView.maxThumbnailWidth()
            - Appearance.edgeInsetsSize * 2
        // don't stretch very small windows; keep them 1:1 in the switcher
        if !isWindowlessApp && imageWidth < thumbnailWidthMax && imageHeight < thumbnailHeightMax {
            return NSSize(width: imageWidth, height: imageHeight)
        }
        let thumbnailHeight = min(imageHeight, thumbnailHeightMax)
        let thumbnailWidth = min(imageWidth, thumbnailWidthMax)
        let imageRatio = imageWidth / imageHeight
        let thumbnailRatio = thumbnailWidth / thumbnailHeight
        var width: CGFloat
        var height: CGFloat
        if thumbnailRatio > imageRatio {
            // Keep the height and reduce the width
            width = imageWidth * thumbnailHeight / imageHeight
            height = thumbnailHeight
        } else if thumbnailRatio < imageRatio {
            // Keep the width and reduce the height
            width = thumbnailWidth
            height = imageHeight * thumbnailWidth / imageWidth
        } else {
            // Enlarge the height to the maximum height and enlarge the width
            width = thumbnailHeightMax / imageHeight * imageWidth
            height = thumbnailHeightMax
        }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    static func iconSize() -> NSSize {
        if Preferences.appearanceStyle == .appIcons {
            let widthMin = ThumbnailView.minThumbnailWidth()
            let contentWidth = Appearance.iconSize
            let frameWidth = contentWidth + Appearance.edgeInsetsSize * 2
            let width = max(frameWidth, widthMin).rounded()
            if widthMin > frameWidth {
                let iconSize = width - Appearance.edgeInsetsSize * 2
                return NSSize(width: iconSize, height: iconSize)
            }
        }
        return NSSize(width: Appearance.iconSize, height: Appearance.iconSize)
    }

    static func height(_ labelHeight: CGFloat) -> CGFloat {
        if Preferences.appearanceStyle == .titles {
            return max(ThumbnailView.iconSize().height, labelHeight) + Appearance.edgeInsetsSize * 2
        } else if Preferences.appearanceStyle == .appIcons {
            return ThumbnailView.iconSize().height + Appearance.edgeInsetsSize * 2 + Appearance.intraCellPadding * 2 + labelHeight
        }
        return ThumbnailView.maxThumbnailHeight()
    }
}

/// Full-height control on the right of each switcher row (past the space-number circle).
/// Implemented as a view (not NSButton) so clicks work reliably in the nonactivating panel.
class EditLabelButton: FlippedView {
    static let width = CGFloat(28)
    static let minHeight = CGFloat(22)
    var onClick: (() -> Void)?
    private var isMouseOver = false
    private var isPressed = false

    init() {
        super.init(frame: NSRect(origin: .zero, size: NSSize(width: EditLabelButton.width, height: EditLabelButton.minHeight)))
        wantsLayer = false
        toolTip = NSLocalizedString("Edit label (AltTab only)", comment: "")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(toolTip)
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        // mouseMoved + activeAlways so hover works even though the switcher panel is non-key
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .mouseMoved,
            .activeAlways,
            .inVisibleRect,
            .enabledDuringMouseDrag,
        ]
        addTrackingArea(NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        setHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        isPressed = false
        setHover(false)
    }

    override func mouseMoved(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        setHover(inside)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if isPressed && inside {
            onClick?()
        }
        isPressed = false
        needsDisplay = true
    }

    /// Called from parent when it knows the pointer is over this control (fallback if tracking areas lag).
    func setHover(_ hovering: Bool) {
        guard isMouseOver != hovering else { return }
        isMouseOver = hovering
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent: NSColor
        if #available(macOS 10.14, *) {
            accent = NSColor.controlAccentColor
        } else {
            accent = NSColor.systemBlue
        }

        // Clear contrast between rest / hover / pressed
        let bg: NSColor
        let border: NSColor
        let symbolColor: NSColor
        if isPressed {
            bg = accent
            border = NSColor.white.withAlphaComponent(0.55)
            symbolColor = .white
        } else if isMouseOver {
            bg = accent.blended(withFraction: 0.25, of: .white) ?? accent
            border = NSColor.white.withAlphaComponent(0.7)
            symbolColor = .white
        } else {
            bg = NSColor.black.withAlphaComponent(0.35)
            border = NSColor.white.withAlphaComponent(0.2)
            symbolColor = NSColor.white.withAlphaComponent(0.85)
        }

        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        bg.setFill()
        path.fill()
        border.setStroke()
        path.lineWidth = isMouseOver || isPressed ? 1.5 : 1
        path.stroke()

        // Slight inner highlight on hover so the state is obvious
        if isMouseOver && !isPressed {
            let inner = NSBezierPath(roundedRect: bounds.insetBy(dx: 2.5, dy: 2.5), xRadius: 4, yRadius: 4)
            NSColor.white.withAlphaComponent(0.12).setFill()
            inner.fill()
        }

        let symbol = "✎" as NSString
        let fontSize: CGFloat = isMouseOver || isPressed ? 15 : 14
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: symbolColor,
        ]
        let size = symbol.size(withAttributes: attrs)
        let point = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2 - 0.5
        )
        symbol.draw(at: point, withAttributes: attrs)
    }
}

/// Inline text field used to type a custom window label without dismissing the switcher.
class ThumbnailLabelEditor: NSTextField {
    var onEscape: (() -> Void)?

    init() {
        super.init(frame: .zero)
        isEditable = true
        isSelectable = true
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        drawsBackground = true
        backgroundColor = NSColor.textBackgroundColor
        textColor = NSColor.labelColor
        focusRingType = .exterior
        cell?.sendsActionOnEndEditing = true
        cell?.wraps = false
        cell?.isScrollable = true
        cell?.usesSingleLineMode = true
        font = Appearance.font
        placeholderString = NSLocalizedString("Custom label", comment: "")
    }

    required init?(coder: NSCoder) {
        fatalError("Class only supports programmatic initialization")
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onEscape?()
            return
        }
        if event.keyCode == UInt16(kVK_Return) || event.keyCode == UInt16(kVK_ANSI_KeypadEnter) {
            sendAction(action, to: target)
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
