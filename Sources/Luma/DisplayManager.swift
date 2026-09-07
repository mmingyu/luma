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

    static func isBuiltInDisplayActive() -> Bool {
        guard let displays = try? activeDisplays() else {
            return false
        }
        return displays.contains { CGDisplayIsBuiltin($0) != 0 }
    }

    static func externalDisplayCount() -> Int {
        guard let displays = try? activeDisplays() else {
            return 0
        }
        return displays.filter { CGDisplayIsBuiltin($0) == 0 }.count
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

        if !enabled, externalDisplayCount() == 0 {
            throw LumaError.noExternalDisplay
        }

        let displayID: CGDirectDisplayID
        if enabled {
            guard let builtIn = try allDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
                throw LumaError.noBuiltInDisplay
            }
            displayID = builtIn
        } else {
            guard let builtIn = try activeDisplays().first(where: { CGDisplayIsBuiltin($0) != 0 }) else {
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
        guard !isBuiltInDisplayActive() else { return }
        try setBuiltInDisplayEnabled(true)
    }

    static func turnBuiltInDisplayOff() throws {
        guard isBuiltInDisplayActive() else { return }
        try setBuiltInDisplayEnabled(false)
    }

    static func toggleBuiltInDisplay() throws {
        if isBuiltInDisplayActive() {
            try turnBuiltInDisplayOff()
        } else {
            try turnBuiltInDisplayOn()
        }
    }
}
