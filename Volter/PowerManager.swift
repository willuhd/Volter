//
//  PowerManager.swift
//  Volter
//
//  Created by Will on 7/6/26.
//

import Foundation

class PowerManager {
    static let shared = PowerManager()
    private init() {}
    
    /// Now delegates to the privileged helper daemon (one Touch ID per launch).
    /// No more AuthorizationExecuteWithPrivileges on every Apply.
    func applySettings(turbo: Bool, powerLimit: Double, lowPowerMode: String, fanSpeed: Double) -> Bool {
        // PrivilegedHelperManager owns the root daemon + socket + token
        return PrivilegedHelperManager.shared.apply(
            turbo: turbo,
            powerLimit: powerLimit,
            lowPowerMode: lowPowerMode,
            fanSpeed: fanSpeed
        )
    }
}
