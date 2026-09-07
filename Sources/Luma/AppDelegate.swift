import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private func displayReconfigurationCallback(
    _ display: CGDirectDisplayID,
    _ flags: CGDisplayChangeSummaryFlags,
    _ userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        delegate.model.scheduleDisplayEvaluation()
    }
}

final class LumaViewModel: ObservableObject {
    private enum DefaultsKey {
        static let autoDisable = "autoDisableWithExternalDisplay"
    }

    @Published private(set) var snapshot: DisplayManager.StatusSnapshot?
    @Published private(set) var readFailed = false
    @Published private(set) var autoDisable: Bool

    private var pendingDisplayEvaluation: DispatchWorkItem?
    var onStateChange: (() -> Void)?

    init() {
        autoDisable = UserDefaults.standard.bool(forKey: DefaultsKey.autoDisable)
    }

    var builtInActive: Bool {
        snapshot?.builtInInActiveList ?? false
    }

    var externalDisplayCount: Int {
        snapshot?.externalDisplayCount ?? 0
    }

    var activeDisplayCount: Int {
        snapshot?.activeDisplayCount ?? 0
    }

    var canToggleBuiltIn: Bool {
        !builtInActive || externalDisplayCount > 0
    }

    func refresh() {
        autoDisable = UserDefaults.standard.bool(forKey: DefaultsKey.autoDisable)

        do {
            snapshot = try DisplayManager.statusSnapshot()
            readFailed = false
        } catch {
            snapshot = nil
            readFailed = true
        }

        onStateChange?()
    }

    func toggleBuiltInDisplay() {
        do {
            try DisplayManager.toggleBuiltInDisplay()
            scheduleDisplayEvaluation(delay: 0.3)
        } catch {
            present(error: error)
            refresh()
        }
    }

    func setAutoDisable(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.autoDisable)
        autoDisable = enabled
        scheduleDisplayEvaluation(delay: 0.1)
    }

    func scheduleDisplayEvaluation(delay: TimeInterval = 0.65) {
        pendingDisplayEvaluation?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.evaluateDisplayState()
        }
        pendingDisplayEvaluation = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelPendingEvaluation() {
        pendingDisplayEvaluation?.cancel()
        pendingDisplayEvaluation = nil
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

        refresh()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LumaViewModel()

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var callbackRegistered = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()
        registerDisplayCallback()

        model.onStateChange = { [weak self] in
            self?.updateStatusItem()
        }
        model.refresh()
        model.scheduleDisplayEvaluation(delay: 0.2)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.cancelPendingEvaluation()

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
        button.target = self
        button.action = #selector(togglePopover)
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 404, height: 706)
        popover.contentViewController = NSHostingController(
            rootView: LumaPanelView(model: model)
        )
    }

    private func registerDisplayCallback() {
        let result = CGDisplayRegisterReconfigurationCallback(
            displayReconfigurationCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )
        callbackRegistered = (result == .success)
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        let symbol: String
        let description: String
        let toolTip: String

        if model.readFailed {
            symbol = "display.trianglebadge.exclamationmark"
            description = "Display status unavailable"
            toolTip = "Luma — Could not read display status"
        } else if model.builtInActive {
            symbol = "display.2"
            description = "Built-in display active"
            toolTip = "Luma — Built-in display is active"
        } else {
            symbol = "display"
            description = "Built-in display disconnected"
            toolTip = "Luma — Built-in display is disconnected"
        }

        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.toolTip = toolTip
    }
}

private struct LumaPanelView: View {
    @ObservedObject var model: LumaViewModel

    private var versionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return "v\(version ?? "0.1.0")"
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            displayStatusCard
            activeDisplayCard
            primaryAction
            automationCard
            commandCard
            footer
        }
        .padding(16)
        .frame(width: 404)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("Luma")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("Smarter displays for a brighter Mac.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                Button("Refresh Status") {
                    model.scheduleDisplayEvaluation(delay: 0)
                }
                Divider()
                Button("Quit Luma") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.secondary.opacity(0.10))
                    .clipShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
    }

    private var displayStatusCard: some View {
        PanelCard {
            VStack(spacing: 0) {
                PanelRow(
                    icon: "laptopcomputer",
                    title: "Built-in Display",
                    subtitle: "Internal Retina Display"
                ) {
                    StatusPill(
                        text: model.readFailed ? "Unknown" : (model.builtInActive ? "Connected" : "Disconnected"),
                        tone: model.readFailed ? .neutral : (model.builtInActive ? .green : .neutral)
                    )
                }

                PanelDivider()

                PanelRow(
                    icon: "list.bullet",
                    title: "In Active List",
                    subtitle: "Is the built-in display in the active list?"
                ) {
                    if model.readFailed {
                        StatusPill(text: "Unknown", tone: .neutral)
                    } else {
                        StatusPill(
                            text: model.builtInActive ? "Yes" : "No",
                            tone: model.builtInActive ? .blue : .green,
                            symbol: model.builtInActive ? nil : "checkmark.circle.fill"
                        )
                    }
                }

                PanelDivider()

                PanelRow(
                    icon: "gearshape.fill",
                    title: "In SkyLight List",
                    subtitle: "Present in macOS SkyLight list"
                ) {
                    skyLightPill
                }
            }
        }
    }

    private var activeDisplayCard: some View {
        PanelCard {
            VStack(spacing: 0) {
                PanelRow(
                    icon: "display",
                    title: "Main Display",
                    subtitle: "Currently driving the desktop"
                ) {
                    StatusPill(
                        text: model.snapshot?.mainDisplayKind.menuDescription ?? "Unknown",
                        tone: model.snapshot?.mainDisplayKind.menuDescription == "External" ? .blue : .neutral
                    )
                }

                PanelDivider()

                PanelRow(
                    icon: "rectangle.on.rectangle",
                    title: "Active Displays",
                    subtitle: "Currently active and visible"
                ) {
                    StatusPill(
                        text: activeDisplaySummary,
                        tone: .neutral
                    )
                }
            }
        }
    }

    private var primaryAction: some View {
        Button {
            model.toggleBuiltInDisplay()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: model.builtInActive ? "moon.fill" : "sun.max.fill")
                    .font(.system(size: 25, weight: .medium))
                    .frame(width: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.builtInActive ? "Turn Off Built-in Display" : "Turn On Built-in Display")
                        .font(.system(size: 16, weight: .semibold))
                    Text(model.builtInActive ? "Use only your external display" : "Re-enable your internal display")
                        .font(.system(size: 12.5))
                        .opacity(0.82)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 18)
            .frame(height: 76)
            .background(
                LinearGradient(
                    colors: [Color.accentColor, Color.blue],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: Color.accentColor.opacity(0.20), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(!model.canToggleBuiltIn)
        .opacity(model.canToggleBuiltIn ? 1 : 0.45)
    }

    private var automationCard: some View {
        PanelCard {
            HStack(spacing: 12) {
                RowIcon(systemName: "rectangle.on.rectangle")

                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto-disable with External Display")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text("Automatically turn off the built-in display when an external display is connected.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Toggle(
                    "",
                    isOn: Binding(
                        get: { model.autoDisable },
                        set: { model.setAutoDisable($0) }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(!DisplayManager.isAppleSilicon)
            }
            .padding(14)
        }
    }

    private var commandCard: some View {
        PanelCard {
            VStack(spacing: 0) {
                Button {
                    model.scheduleDisplayEvaluation(delay: 0)
                } label: {
                    CommandRow(icon: "arrow.clockwise", title: "Refresh Status", shortcut: "⌘ R")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)

                PanelDivider(inset: 50)

                Button {
                    NSApp.terminate(nil)
                } label: {
                    CommandRow(icon: "power", title: "Quit Luma", shortcut: "⌘ Q")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("Less light. More focus.")
            Spacer()
            Text(versionText)
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .padding(.top, 1)
    }

    @ViewBuilder
    private var skyLightPill: some View {
        if model.readFailed {
            StatusPill(text: "Unknown", tone: .neutral)
        } else {
            switch model.snapshot?.builtInInAllDisplayList {
            case .some(true):
                StatusPill(
                    text: model.builtInActive ? "Yes" : "Yes (disabled)",
                    tone: model.builtInActive ? .blue : .amber,
                    symbol: model.builtInActive ? nil : "exclamationmark.circle.fill"
                )
            case .some(false):
                StatusPill(text: "No", tone: .neutral)
            case .none:
                StatusPill(text: "Unknown", tone: .neutral)
            }
        }
    }

    private var activeDisplaySummary: String {
        guard !model.readFailed else { return "Unknown" }
        if model.externalDisplayCount > 0 {
            return "\(model.externalDisplayCount) external"
        }
        return "\(model.activeDisplayCount) active"
    }
}

private struct PanelCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.primary.opacity(0.055), lineWidth: 1)
            }
    }
}

private struct PanelRow<Accessory: View>: View {
    let icon: String
    let title: String
    let subtitle: String
    let accessory: Accessory

    init(
        icon: String,
        title: String,
        subtitle: String,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            RowIcon(systemName: icon)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            accessory
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 64)
    }
}

private struct RowIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 38, height: 38)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct CommandRow: View {
    let icon: String
    let title: String
    let shortcut: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 30)

            Text(title)
                .font(.system(size: 14, weight: .medium))

            Spacer()

            Text(shortcut)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 14)
        .frame(height: 51)
    }
}

private struct PanelDivider: View {
    var inset: CGFloat = 62

    var body: some View {
        Divider()
            .padding(.leading, inset)
    }
}

private enum PillTone {
    case neutral
    case blue
    case green
    case amber

    var foreground: Color {
        switch self {
        case .neutral: return .secondary
        case .blue: return .blue
        case .green: return .green
        case .amber: return .orange
        }
    }

    var background: Color {
        foreground.opacity(0.13)
    }
}

private struct StatusPill: View {
    let text: String
    let tone: PillTone
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tone.background)
        .clipShape(Capsule())
    }
}
