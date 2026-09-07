import AppKit
import CoreGraphics
import Foundation

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.scheduleDisplayEvaluation()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum DefaultsKey {
        static let autoDisable = "autoDisableWithExternalDisplay"
    }

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()

    private let statusMenuItem = NSMenuItem(title: "Built-in Display: Checking…", action: nil, keyEquivalent: "")
    private let activeListMenuItem = NSMenuItem(title: "Built-in in Active List: Checking…", action: nil, keyEquivalent: "")
    private let allListMenuItem = NSMenuItem(title: "Built-in in SkyLight List: Checking…", action: nil, keyEquivalent: "")
    private let mainDisplayMenuItem = NSMenuItem(title: "macOS Main Display: Checking…", action: nil, keyEquivalent: "")
    private let displayCountMenuItem = NSMenuItem(title: "Active Displays: Checking…", action: nil, keyEquivalent: "")
    private let toggleMenuItem = NSMenuItem(title: "Toggle Built-in Display", action: nil, keyEquivalent: "")
    private let autoMenuItem = NSMenuItem(title: "Auto-disable with External Display", action: nil, keyEquivalent: "")

    private var pendingDisplayEvaluation: DispatchWorkItem?
    private var callbackRegistered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configureMenu()
        registerDisplayCallback()
        refreshMenu()
        scheduleDisplayEvaluation(delay: 0.2)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pendingDisplayEvaluation?.cancel()
        if callbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "Luma")
        button.image?.isTemplate = true
        button.toolTip = "Luma — Built-in Display Control"
        statusItem.menu = menu
    }

    private func configureMenu() {
        menu.delegate = self

        for item in [statusMenuItem, activeListMenuItem, allListMenuItem, mainDisplayMenuItem, displayCountMenuItem] {
            item.isEnabled = false
            menu.addItem(item)
        }
        menu.addItem(.separator())

        toggleMenuItem.target = self
        toggleMenuItem.action = #selector(toggleBuiltInDisplay)
        menu.addItem(toggleMenuItem)

        autoMenuItem.target = self
        autoMenuItem.action = #selector(toggleAutoDisable)
        menu.addItem(autoMenuItem)

        menu.addItem(.separator())

        let refreshItem = NSMenuItem(title: "Refresh Status", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let quitItem = NSMenuItem(title: "Quit Luma", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func registerDisplayCallback() {
        let result = CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        callbackRegistered = (result == .success)
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu()
    }

    @objc private func toggleBuiltInDisplay() {
        do {
            try DisplayManager.toggleBuiltInDisplay()
            scheduleDisplayEvaluation(delay: 0.3)
        } catch {
            present(error: error)
            refreshMenu()
        }
    }

    @objc private func toggleAutoDisable() {
        let defaults = UserDefaults.standard
        let newValue = !defaults.bool(forKey: DefaultsKey.autoDisable)
        defaults.set(newValue, forKey: DefaultsKey.autoDisable)
        refreshMenu()
        scheduleDisplayEvaluation(delay: 0.1)
    }

    @objc private func refreshFromMenu() {
        scheduleDisplayEvaluation(delay: 0)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func scheduleDisplayEvaluation(delay: TimeInterval = 0.65) {
        pendingDisplayEvaluation?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateDisplayState()
        }
        pendingDisplayEvaluation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func evaluateDisplayState() {
        pendingDisplayEvaluation = nil

        do {
            let snapshot = try DisplayManager.statusSnapshot()
            let autoDisable = UserDefaults.standard.bool(forKey: DefaultsKey.autoDisable)

            // Fail-safe: never intentionally leave the Mac with no active display.
            if snapshot.builtInDisconnectedFromActiveList && snapshot.externalDisplayCount == 0 {
                try DisplayManager.turnBuiltInDisplayOn()
            } else if autoDisable && snapshot.builtInInActiveList && snapshot.externalDisplayCount > 0 {
                try DisplayManager.turnBuiltInDisplayOff()
            }
        } catch {
            present(error: error)
        }

        refreshMenu()
    }

    private func refreshMenu() {
        let autoDisable = UserDefaults.standard.bool(forKey: DefaultsKey.autoDisable)

        do {
            let snapshot = try DisplayManager.statusSnapshot()
            let builtInActive = snapshot.builtInInActiveList

            statusMenuItem.title = "Built-in Display: \(builtInActive ? "On" : "Off")"
            activeListMenuItem.title = builtInActive
                ? "Built-in in Active List: Yes — Recognized"
                : "Built-in in Active List: No — Disconnected ✓"

            switch snapshot.builtInInAllDisplayList {
            case .some(true):
                allListMenuItem.title = builtInActive
                    ? "Built-in in SkyLight List: Yes"
                    : "Built-in in SkyLight List: Yes — Disabled"
            case .some(false):
                allListMenuItem.title = "Built-in in SkyLight List: No"
            case .none:
                allListMenuItem.title = "Built-in in SkyLight List: Unknown"
            }

            mainDisplayMenuItem.title = "macOS Main Display: \(snapshot.mainDisplayKind.menuDescription)"
            displayCountMenuItem.title = "Active Displays: \(snapshot.activeDisplayCount) (External: \(snapshot.externalDisplayCount))"

            if builtInActive {
                toggleMenuItem.title = "Turn Built-in Display Off"
                toggleMenuItem.isEnabled = snapshot.externalDisplayCount > 0
            } else {
                toggleMenuItem.title = "Turn Built-in Display On"
                toggleMenuItem.isEnabled = true
            }

            statusItem.button?.image = NSImage(
                systemSymbolName: builtInActive ? "display.2" : "display",
                accessibilityDescription: builtInActive ? "Built-in display active" : "Built-in display disconnected"
            )
            statusItem.button?.toolTip = builtInActive
                ? "Luma — Built-in display is active"
                : "Luma — Built-in display is absent from the CoreGraphics active list"
        } catch {
            statusMenuItem.title = "Built-in Display: Unknown"
            activeListMenuItem.title = "Built-in in Active List: Read failed"
            allListMenuItem.title = "Built-in in SkyLight List: Read failed"
            mainDisplayMenuItem.title = "macOS Main Display: Unknown"
            displayCountMenuItem.title = "Active Displays: Unknown"
            toggleMenuItem.title = "Toggle Built-in Display"
            toggleMenuItem.isEnabled = false
            statusItem.button?.toolTip = "Luma — Could not read display status"
        }

        autoMenuItem.state = autoDisable ? .on : .off
        autoMenuItem.isEnabled = DisplayManager.isAppleSilicon
        statusItem.button?.image?.isTemplate = true
    }

    private func present(error: Error) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Luma couldn't change the display state"
        alert.informativeText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
