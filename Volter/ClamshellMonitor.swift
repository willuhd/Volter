//
//  ClamshellMonitor.swift
//  Volter
//
//  App-side lid-open observer. Observing power notifications needs no
//  privileges, so the app watches the clamshell directly instead of adding a
//  push channel to the helper protocol. The helper keeps the sleep policy
//  steady; this monitor only reports closed → open transitions so the app
//  can lock the screen (see ScreenLock).
//
//  Same IOKit interest mechanism as VolterHelper's ClamshellObserver.
//  All state lives on `queue`; the callback already runs there.
//

import Foundation
import IOKit
import IOKit.pwr_mgt

extension Notification.Name {
    /// Posted on the main queue on every closed → open lid transition.
    static let volterLidOpened = Notification.Name("VolterLidOpened")
}

/// General-interest message delivered on clamshell transitions.
private let kClamshellMessageID: UInt32 = 0xe003_4100

final class ClamshellMonitor {
    static let shared = ClamshellMonitor()

    private let queue = DispatchQueue(label: "Volter.ClamshellMonitor", qos: .userInitiated)
    private var port: OpaquePointer?
    private var notification: io_object_t = IO_OBJECT_NULL
    private var lastLidClosed: Bool?

    private let callback: IOServiceInterestCallback = { refCon, _, messageType, messageArgument in
        guard messageType == kClamshellMessageID, let refCon else { return }
        let monitor = Unmanaged<ClamshellMonitor>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        let bits = messageArgument.map { UInt(bitPattern: $0) } ?? 0
        // Runs on monitor.queue (see start), so direct state access is safe.
        monitor.handleClamshellClosed((bits & UInt(kClamshellStateBit)) != 0)
    }

    private init() {}

    /// Idempotent. Safe to call from app launch.
    func start() {
        queue.sync {
            guard self.port == nil else { return }
            guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
                NSLog("[Volter] clamshell monitor: no notification port")
                return
            }
            self.port = port
            IONotificationPortSetDispatchQueue(port, queue)

            let root = IOServiceGetMatchingService(
                kIOMainPortDefault,
                IOServiceMatching("IOPMrootDomain")
            )
            guard root != IO_OBJECT_NULL else {
                IONotificationPortDestroy(port)
                self.port = nil
                NSLog("[Volter] clamshell monitor: no IOPMrootDomain")
                return
            }
            defer { IOObjectRelease(root) }

            let context = Unmanaged.passUnretained(self).toOpaque()
            let result = IOServiceAddInterestNotification(
                port,
                root,
                kIOGeneralInterest,
                callback,
                context,
                &notification
            )
            guard result == KERN_SUCCESS else {
                IONotificationPortDestroy(port)
                self.port = nil
                NSLog("[Volter] clamshell monitor unavailable: 0x\(String(result, radix: 16))")
                return
            }

            lastLidClosed = readClamshellClosed()
        }
    }

    private func handleClamshellClosed(_ closed: Bool) {
        let wasClosed = lastLidClosed ?? false
        lastLidClosed = closed
        guard !closed, wasClosed else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .volterLidOpened, object: nil)
        }
    }

    private func readClamshellClosed() -> Bool? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceNameMatching("IOPMrootDomain")
        )
        guard service != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        ) else { return nil }
        let value = unmanaged.takeRetainedValue()
        guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(value as! CFBoolean)
    }
}
