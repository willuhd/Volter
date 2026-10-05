//
//  ScreenLock.swift
//  Volter
//
//  Locks the console session without system sleep (remote sessions survive).
//  Primary: private SACLockScreenImmediate() via runtime dlopen — a real lock
//  regardless of the user's password-delay setting, no Accessibility
//  permission, no keystroke simulation. The symbol is private (never in the
//  public SDK), so it is resolved at runtime; if Apple ever removes it, the
//  fallback below keeps working.
//  Fallback: `pmset displaysleepnow` (unprivileged). Only lands on the lock
//  screen when Lock Screen → "Require password" is Immediate.
//

import Foundation
import Darwin

enum ScreenLock {
    /// Lock the screen. Returns true if a lock was requested.
    @discardableResult
    static func lock() -> Bool {
        if lockViaPrivateAPI() {
            return true
        }
        NSLog("[Volter] SACLockScreenImmediate unavailable, falling back to displaysleepnow")
        return lockViaDisplaySleep()
    }

    private static func lockViaPrivateAPI() -> Bool {
        let path = "/System/Library/PrivateFrameworks/login.framework/login"
        guard let handle = dlopen(path, RTLD_NOW) else { return false }
        defer { dlclose(handle) }
        guard let sym = dlsym(handle, "SACLockScreenImmediate") else { return false }
        typealias LockFn = @convention(c) () -> Int32
        let fn = unsafeBitCast(sym, to: LockFn.self)
        _ = fn()
        return true
    }

    private static func lockViaDisplaySleep() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            return true
        } catch {
            NSLog("[Volter] displaysleepnow failed: \(error.localizedDescription)")
            return false
        }
    }
}
