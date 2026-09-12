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
import Darwin

class PowerManager {
    static let shared = PowerManager()
    private init() {}

    struct GPUStatus {
        /// Hard default cap (100W on all Apple Silicon).
        let defaultMaxWatts: Double
        /// Currently applied cap.
        let capWatts: Double
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

    // MARK: - Chip label (sudoless sysctl)

    static func chipName() -> String {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return "Volter"
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buf, &size, nil, 0) == 0 else {
            return "Volter"
        }
        let full = String(cString: buf) // e.g. "Apple M5 Pro"
        let short = full.replacingOccurrences(of: "Apple ", with: "")
        return short.isEmpty ? "Volter" : short
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
