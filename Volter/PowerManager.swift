//
//  PowerManager.swift
//  Volter
//
//  Apple Silicon edition: single GPU power-cap control.
//  Display reads are sudoless direct IOKit (no helper, no password);
//  the privileged helper spawns only on Apply/restore.
//

import Foundation
import IOKit

class PowerManager {
    static let shared = PowerManager()
    private init() {}

    struct GPUStatus {
        /// Hard default cap (100W on all Apple Silicon).
        let defaultMaxWatts: Double
        /// Currently applied cap.
        let capWatts: Double
    }

    struct PowerPolicyStatus {
        let disableSleep: Bool
        let stealth: Bool
    }

    /// Hard "Max": 100W on all Apple Silicon (mirrors the helper's kDefaultMaxMW).
    /// Reaching this on the slider snaps to restore instead of writing.
    static let snapToMaxWatts = 28.0

    private func convert(origMW: Int64, maxMW: Int64) -> GPUStatus? {
        guard maxMW > 0, origMW > 0 else { return nil }
        return GPUStatus(
            defaultMaxWatts: Double(origMW) / 1000.0,
            capWatts: Double(maxMW) / 1000.0
        )
    }

    // MARK: - Sudoless direct AGX read (display path, no password)

    private func directMaxMW() -> Int64? {
        let classes = ["AGXAcceleratorG17X", "AGXAcceleratorG16G", "AGXAcceleratorG15X",
                       "AGXAcceleratorG15G", "AGXAcceleratorG14X", "AGXAcceleratorG13G",
                       "AGXAccelerator"]
        for cls in classes {
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls))
            if svc == 0 { continue }
            defer { IOObjectRelease(svc) }
            guard let unmanaged = IORegistryEntryCreateCFProperty(
                svc, "MaxGPUAbsolutePower" as CFString, kCFAllocatorDefault, 0) else { continue }
            let raw = unmanaged.takeRetainedValue()
            guard CFGetTypeID(raw) == CFNumberGetTypeID() else { continue }
            var value: Int64 = 0
            guard CFNumberGetValue(raw as! CFNumber, .sInt64Type, &value) else { continue }
            return value
        }
        return nil
    }

    /// Reads the system-wide sleep override directly from IOPMrootDomain.
    func readDisableSleep() -> Bool? {
        let svc = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceNameMatching("IOPMrootDomain")
        )
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }

        guard let unmanaged = IORegistryEntryCreateCFProperty(
            svc,
            "SleepDisabled" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }

        let value = unmanaged.takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(value as! CFBoolean)
    }

    func setDisableSleep(_ enabled: Bool) -> PowerPolicyStatus? {
        // Avoid launching/authenticating the helper when the requested state
        // is already the live system state.
        if !enabled && readDisableSleep() == false {
            return PowerPolicyStatus(disableSleep: false, stealth: false)
        }
        guard let status = PrivilegedHelperManager.shared.setDisableSleep(enabled) else {
            return nil
        }
        return PowerPolicyStatus(
            disableSleep: status.sleepDisabled,
            stealth: status.stealthEnabled
        )
    }

    func setStealth(_ enabled: Bool) -> PowerPolicyStatus? {
        if !enabled && readDisableSleep() == false {
            return PowerPolicyStatus(disableSleep: false, stealth: false)
        }
        guard let status = PrivilegedHelperManager.shared.setStealth(enabled) else {
            return nil
        }
        return PowerPolicyStatus(
            disableSleep: status.sleepDisabled,
            stealth: status.stealthEnabled
        )
    }

    /// Read current GPU state. Tries sudoless direct read first (no password);
    /// falls back to the helper (one Touch ID) if the driver isn't visible.
    func readStatus() -> GPUStatus? {
        if let live = directMaxMW() {
            return convert(origMW: live, maxMW: live)
        }
        guard let s = PrivilegedHelperManager.shared.status() else { return nil }
        return convert(origMW: s.origMaxMW, maxMW: s.maxCapMW)
    }

    /// Cap the GPU. 0 (Auto) or at/above snapToMaxWatts restores max instead.
    /// Neither is ever sent to the helper (floor 1W) — both map to restore.
    func applyCap(watts: Double) -> GPUStatus? {
        if watts < 0.001 || watts >= Self.snapToMaxWatts - 0.001 {
            return restoreMax()
        }
        let mW = Int64((watts * 1000.0).rounded())
        guard let s = PrivilegedHelperManager.shared.applyCap(mW: mW) else { return nil }
        return convert(origMW: s.origMaxMW, maxMW: s.maxCapMW)
    }

    /// Restore the machine default cap ("max" / Auto).
    func restoreMax() -> GPUStatus? {
        guard let s = PrivilegedHelperManager.shared.restoreMax() else { return nil }
        return convert(origMW: s.origMaxMW, maxMW: s.maxCapMW)
    }
}
