import CoreGraphics
import Darwin
import Foundation

enum DisplayManager {
    enum LumaError: LocalizedError {
        case unsupportedArchitecture
        case skyLightUnavailable
        case symbolUnavailable(String)
        case noBuiltInDisplay
        case noExternalDisplay
        case displayListFailed(CGError)
        case beginConfigurationFailed(CGError)
        case configureFailed(CGError)
        case commitFailed(CGError)

        var errorDescription: String? {
            switch self {
            case .unsupportedArchitecture:
                return "Luma only supports Apple Silicon Macs."
            case .skyLightUnavailable:
                return "Could not load the SkyLight private framework."
            case .symbolUnavailable(let symbol):
                return "Could not resolve SkyLight symbol: \(symbol)."
            case .noBuiltInDisplay:
                return "The built-in display could not be found."
            case .noExternalDisplay:
                return "Connect an external display before turning the built-in display off."
            case .displayListFailed(let error):
                return "Could not read the display list (CGError \(error.rawValue))."
            case .beginConfigurationFailed(let error):
                return "Could not begin a display configuration (CGError \(error.rawValue))."
            case .configureFailed(let error):
                return "Could not change the built-in display state (CGError \(error.rawValue))."
            case .commitFailed(let error):
                return "Could not commit the display configuration (CGError \(error.rawValue))."
            }
        }
    }

    enum MainDisplayKind {
        case builtIn
        case external
        case unavailable

        var menuDescription: String {
            switch self {
            case .builtIn:
                return "Built-in"
            case .external:
                return "External"
            case .unavailable:
                return "Unknown"
            }
        }
    }

    struct StatusSnapshot {
        let activeDisplayIDs: [CGDirectDisplayID]
        let mainDisplayID: CGDirectDisplayID
        let builtInInActiveList: Bool
        let builtInInAllDisplayList: Bool?
        let externalDisplayCount: Int
        let mainDisplayKind: MainDisplayKind

        var activeDisplayCount: Int {
            activeDisplayIDs.count
        }

        /// True when CoreGraphics no longer sees the built-in panel as an active display.
        /// This distinguishes a real disconnect from simply dimming/blackening the panel.
        var builtInDisconnectedFromActiveList: Bool {
            !builtInInActiveList
        }
    }

    private enum SkyLight {
        private static let frameworkPath = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"

        typealias GetDisplayListFunction = @convention(c) (
            UInt32,
            UnsafeMutablePointer<CGDirectDisplayID>?,
            UnsafeMutablePointer<UInt32>?
        ) -> CGError

        typealias ConfigureDisplayEnabledFunction = @convention(c) (
            CGDisplayConfigRef,
            CGDirectDisplayID,
            Bool
        ) -> CGError

        static let handle: UnsafeMutableRawPointer? = dlopen(frameworkPath, RTLD_LAZY | RTLD_LOCAL)

        static let getDisplayList: GetDisplayListFunction? = loadSymbol(
            "SLSGetDisplayList",
            as: GetDisplayListFunction.self
        )

        static let configureDisplayEnabled: ConfigureDisplayEnabledFunction? = loadSymbol(
            "SLSConfigureDisplayEnabled",
            as: ConfigureDisplayEnabledFunction.self
        )

        private static func loadSymbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let handle, let symbol = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(symbol, to: type)
        }
    }

    static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    static func activeDisplays() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &count)
        guard countResult == .success else {
            throw LumaError.displayListFailed(countResult)
        }

        guard count > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = displays.withUnsafeMutableBufferPointer { buffer in
            CGGetActiveDisplayList(count, buffer.baseAddress, &count)
        }
        guard listResult == .success else {
            throw LumaError.displayListFailed(listResult)
        }

        return Array(displays.prefix(Int(count)))
    }

    static func allDisplays() throws -> [CGDirectDisplayID] {
        guard isAppleSilicon else {
            throw LumaError.unsupportedArchitecture
        }
        guard SkyLight.handle != nil else {
            throw LumaError.skyLightUnavailable
        }
        guard let getDisplayList = SkyLight.getDisplayList else {
            throw LumaError.symbolUnavailable("SLSGetDisplayList")
        }

        var count: UInt32 = 0
        let countResult = getDisplayList(0, nil, &count)
        guard countResult == .success else {
            throw LumaError.displayListFailed(countResult)
        }

        guard count > 0 else {
            return []
        }

        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = displays.withUnsafeMutableBufferPointer { buffer in
            getDisplayList(count, buffer.baseAddress, &count)
        }
        guard listResult == .success else {
            throw LumaError.displayListFailed(listResult)
        }

        return Array(displays.prefix(Int(count)))
    }

    static func statusSnapshot() throws -> StatusSnapshot {
        let active = try activeDisplays()
        let builtInInActiveList = active.contains { CGDisplayIsBuiltin($0) != 0 }
        let externalCount = active.filter { CGDisplayIsBuiltin($0) == 0 }.count
        let mainDisplayID = CGMainDisplayID()

        let mainDisplayKind: MainDisplayKind
        if !active.contains(mainDisplayID) {
            mainDisplayKind = .unavailable
        } else if CGDisplayIsBuiltin(mainDisplayID) != 0 {
            mainDisplayKind = .builtIn
        } else {
            mainDisplayKind = .external
        }

        let builtInInAllDisplayList: Bool?
        if isAppleSilicon, let all = try? allDisplays() {
            builtInInAllDisplayList = all.contains { CGDisplayIsBuiltin($0) != 0 }
        } else {
            builtInInAllDisplayList = nil
        }

        return StatusSnapshot(
            activeDisplayIDs: active,
            mainDisplayID: mainDisplayID,
            builtInInActiveList: builtInInActiveList,
            builtInInAllDisplayList: builtInInAllDisplayList,
            externalDisplayCount: externalCount,
            mainDisplayKind: mainDisplayKind
        )
    }

    static func isBuiltInDisplayActive() -> Bool {
        (try? statusSnapshot().builtInInActiveList) ?? false
    }

    static func externalDisplayCount() -> Int {
        (try? statusSnapshot().externalDisplayCount) ?? 0
    }

    static func setBuiltInDisplayEnabled(_ enabled: Bool) throws {
        guard isAppleSilicon else {
            throw LumaError.unsupportedArchitecture
        }
        guard SkyLight.handle != nil else {
            throw LumaError.skyLightUnavailable
        }
        guard let configureDisplayEnabled = SkyLight.configureDisplayEnabled else {
            throw LumaError.symbolUnavailable("SLSConfigureDisplayEnabled")
        }

        let snapshot = try statusSnapshot()
        if !enabled, snapshot.externalDisplayCount == 0 {
            throw LumaError.noExternalDisplay
        }

        let displayID: CGDirectDisplayID
        if enabled {
            guard let builtIn = try allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
                throw LumaError.noBuiltInDisplay
            }
            displayID = builtIn
        } else {
            guard let builtIn = snapshot.activeDisplayIDs.first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
                throw LumaError.noBuiltInDisplay
            }
            displayID = builtIn
        }

        var configuration: CGDisplayConfigRef?
        let beginResult = CGBeginDisplayConfiguration(&configuration)
        guard beginResult == .success, let configuration else {
            throw LumaError.beginConfigurationFailed(beginResult)
        }

        let configureResult = configureDisplayEnabled(configuration, displayID, enabled)
        guard configureResult == .success else {
            CGCancelDisplayConfiguration(configuration)
            throw LumaError.configureFailed(configureResult)
        }

        let commitResult = CGCompleteDisplayConfiguration(configuration, .permanently)
        guard commitResult == .success else {
            throw LumaError.commitFailed(commitResult)
        }
    }

    static func turnBuiltInDisplayOn() throws {
        guard !(try statusSnapshot()).builtInInActiveList else { return }
        try setBuiltInDisplayEnabled(true)
    }

    static func turnBuiltInDisplayOff() throws {
        guard (try statusSnapshot()).builtInInActiveList else { return }
        try setBuiltInDisplayEnabled(false)
    }

    static func toggleBuiltInDisplay() throws {
        if (try statusSnapshot()).builtInInActiveList {
            try turnBuiltInDisplayOff()
        } else {
            try turnBuiltInDisplayOn()
        }
    }
}
