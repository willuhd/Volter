//
//  PowerManager.swift
//  Volter
//
//  Created by Will on 7/6/26.
//

import Foundation
import Security
import Darwin

class PowerManager {
    static let shared = PowerManager()
    
    // Persistent authorization reference to enable system-level credential caching
    private var authRef: AuthorizationRef? = nil
    
    // Define the C function signature matching the original API
    private typealias AuthorizationExecuteWithPrivilegesFunc = @convention(c) (
        AuthorizationRef,                             // authorization
        UnsafePointer<CChar>,                         // pathToTool
        AuthorizationFlags,                           // options
        UnsafePointer<UnsafeMutablePointer<CChar>?>?, // arguments
        UnsafeMutablePointer<UnsafeMutablePointer<FILE>?>? // communicationsPipe
    ) -> OSStatus

    // Dynamically resolve the legacy function pointer from the Security framework at runtime
    private static let legacyExecuteFunc: AuthorizationExecuteWithPrivilegesFunc? = {
        let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        guard let sym = dlsym(handle, "AuthorizationExecuteWithPrivileges") else {
            return nil
        }
        return unsafeBitCast(sym, to: AuthorizationExecuteWithPrivilegesFunc.self)
    }()
    
    private init() {
        var tempRef: AuthorizationRef? = nil
        let status = AuthorizationCreate(nil, nil, [], &tempRef)
        if status == errAuthorizationSuccess {
            self.authRef = tempRef
        }
    }
    
    /// Converts an RPM integer to the SMC little-endian IEEE 754 hex string.
    private func fanSpeedToHex(_ rpm: Int) -> String {
        let floatValue = Float(rpm)
        let bits = floatValue.bitPattern
        let b0 = UInt8(bits & 0xFF)
        let b1 = UInt8((bits >> 8) & 0xFF)
        let b2 = UInt8((bits >> 16) & 0xFF)
        let b3 = UInt8((bits >> 24) & 0xFF)
        return String(format: "%02x%02x%02x%02x", b0, b1, b2, b3)
    }
    
    /// Prepares and runs the privileged helper tasks using the native Security Framework.
    func applySettings(turbo: Bool, powerLimit: Double, lowPowerMode: String, fanSpeed: Double) -> Bool {
        guard let bundledBinaryPath = Bundle.main.path(forResource: "voltageshift", ofType: nil),
              let bundledKextPath = Bundle.main.path(forResource: "VoltageShift", ofType: "kext"),
              let bundledSmcPath = Bundle.main.path(forResource: "smc", ofType: nil) else {
            print("Error: voltageshift, VoltageShift.kext, or smc not found in app bundle.")
            return false
        }
        
        let secureDir = "/Library/Application Support/Volter"
        var commands: [String] = []
        
        // 1. Setup secure directory
        commands.append("mkdir -p '\(secureDir)'")
        
        // 2. Create a dummy pass-through 'sudo' wrapper to bypass nested PAM prompts
        commands.append("printf '#!/bin/sh\\nexec \"$@\"\\n' > '\(secureDir)/sudo'")
        commands.append("chmod +x '\(secureDir)/sudo'")
        
        // 3. Prepend our secure directory to PATH so the dummy 'sudo' is prioritized
        commands.append("export PATH='\(secureDir)':$PATH")
        
        // 4. Copy assets and assign root permissions
        commands.append("cp -Rf '\(bundledBinaryPath)' '\(secureDir)/'")
        commands.append("cp -Rf '\(bundledKextPath)' '\(secureDir)/'")
        commands.append("cp -Rf '\(bundledSmcPath)' '\(secureDir)/'")
        commands.append("chown -R root:wheel '\(secureDir)'")
        commands.append("chmod -R 755 '\(secureDir)'")
        
        // 5. Pre-emptively load the kext using native root kextload (bypassing the binary's fallback load)
        commands.append("kextstat | grep -q 'VoltageShift' || kextload '\(secureDir)/VoltageShift.kext'")
        
        // 6. Run voltageshift commands (inheriting the dummy sudo)
        let turboValue = turbo ? 1 : 0
        commands.append("'\(secureDir)/voltageshift' turbo \(turboValue)")
        
        let plValue = Int(powerLimit)
        if plValue > 0 {
            let rawLimit = plValue * 8
            let hexValue = String(format: "%03x", rawLimit)
            let writeArg = "0x428\(hexValue)00DD8\(hexValue)"
            commands.append("'\(secureDir)/voltageshift' write 0x610 \(writeArg)")
        }
        
        // 7. Apply fan speed via SMC
        let fanValue = Int(fanSpeed)
        if fanValue > 0 {
            let hexRPM = fanSpeedToHex(fanValue)
            commands.append("'\(secureDir)/smc' -k \"F0Md\" -w 01")
            commands.append("'\(secureDir)/smc' -k \"F0Tg\" -w \(hexRPM)")
        } else {
            // Reset fan to automatic control
            commands.append("'\(secureDir)/smc' -k \"F0Md\" -w 00")
        }
        
        // 8. Apply native Low Power Mode
        switch lowPowerMode {
        case "On":
            commands.append("pmset -a lowpowermode 1")
        case "Battery":
            commands.append("pmset -b lowpowermode 1")
            commands.append("pmset -c lowpowermode 0")
        default: // "Off"
            commands.append("pmset -a lowpowermode 0")
        }
        
        let combinedScript = commands.joined(separator: " && ")
        return executePrivileged(shellScript: combinedScript)
    }
    
    /// Executes commands inside an administrator-level context using the cached authorization reference.
    private func executePrivileged(shellScript: String) -> Bool {
        guard let authRef = self.authRef else {
            print("Error: Authorization reference is uninitialized.")
            return false
        }
        
        guard let executeFunc = Self.legacyExecuteFunc else {
            print("Error: AuthorizationExecuteWithPrivileges symbol could not be loaded dynamically.")
            return false
        }
        
        let tool = "/bin/sh"
        let args = ["-c", shellScript]
        
        var cArgs = args.map { strdup($0) }
        cArgs.append(nil)
        
        defer {
            for ptr in cArgs {
                if let p = ptr { free(p) }
            }
        }
        
        let status = cArgs.withUnsafeBufferPointer { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else {
                return errAuthorizationInternal
            }
            
            return executeFunc(
                authRef,
                tool,
                [],
                baseAddress,
                nil
            )
        }
        
        return status == errAuthorizationSuccess
    }
}
