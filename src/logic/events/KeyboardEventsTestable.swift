import ShortcutRecorder
import Carbon.HIToolbox.Events

class KeyboardEventsTestable {
    static let globalShortcutsIds = [
        "nextWindowShortcut": 0,
        "nextWindowShortcut2": 1,
        "nextWindowShortcut3": 2,
        "holdShortcut": 5,
        "holdShortcut2": 6,
        "holdShortcut3": 7,
    ]
}

@discardableResult
func handleKeyboardEvent(_ globalId: Int?, _ shortcutState: ShortcutState?, _ keyCode: UInt32?, _ modifiers: NSEvent.ModifierFlags?, _ isARepeat: Bool) -> Bool {
    Logger.debug(globalId, shortcutState, keyCode, modifiers, isARepeat, NSEvent.modifierFlags)
    // While editing a window label, let key events reach the text field.
    // Escape cancels editing; hold-key release is already suppressed via forceDoNothingOnRelease.
    if App.app.isEditingWindowLabel {
        if let keyCode, keyCode == UInt32(kVK_Escape) {
            WindowLabels.cancelEditingIfNeeded()
            return true
        }
        // Still track hold-shortcut state so release doesn't get stuck, but don't execute actions.
        for shortcut in ControlsTab.shortcuts.values {
            _ = shortcut.matches(globalId, shortcutState, keyCode, modifiers)
        }
        return false
    }
    var someShortcutTriggered = false
    for shortcut in ControlsTab.shortcuts.values {
        if shortcut.matches(globalId, shortcutState, keyCode, modifiers) && shortcut.shouldTrigger() {
            shortcut.executeAction(isARepeat)
            // we want to pass-through alt-up to the active app, since it saw alt-down previously
            if !shortcut.id.starts(with: "holdShortcut") {
                someShortcutTriggered = true
            }
        }
        shortcut.redundantSafetyMeasures()
    }
    // TODO if we manage to move all keyboard listening to the background thread, we'll have issues returning this boolean
    // this function uses many objects that are also used on the main-thread. It also executes the actions
    // we'll have to rework this whole approach. Today we rely on somewhat in-order events/actions
    // special attention should be given to App.app.appIsBeingUsed which is being set to true when executing the nextWindowShortcut action
    return someShortcutTriggered
}
