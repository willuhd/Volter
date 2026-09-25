//
//  main.swift
//  VolterHelper - Privileged helper daemon (runs as root)
//  Apple Silicon edition: GPU power-cap control via the AGX driver.
//  No kext, no MSR, no SMC writes.
//
//  AGX interface ported from maderix/apple-gpu-dvfs,
//  MIT License, Copyright (c) 2026 Manjeet Singh:
//    write {"SetMaxGPUAbsolutePower": true, "AbsoluteTarget": mW}
//    read  "MaxGPUAbsolutePower" (current cap, mW)
//
//  Comunicates via Unix Domain Socket with token auth.
//  One Touch ID per app launch. No Apple Developer certificate required.
//

import Foundation
import Dispatch
import IOKit
import IOKit.pwr_mgt
import Darwin

// MARK: - AGX GPU Interface

/// Ordered by generation (newest first); plain "AGXAccelerator" last as catch-all.
let kAGXClasses = [
    "AGXAcceleratorG17X",
    "AGXAcceleratorG16G",
    "AGXAcceleratorG15X",
    "AGXAcceleratorG15G",
    "AGXAcceleratorG14X",
    "AGXAcceleratorG13G",
    "AGXAccelerator",
]

/// Firmware floor observed upstream (1W "min" preset). Never write below this.
let kMinCapMW: Int64 = 1000

/// First matching AGX service. Caller must IOObjectRelease when done.
func agxService() -> io_service_t {
    for cls in kAGXClasses {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(cls))
        if svc != 0 { return svc }
    }
    return 0
}

func agxReadInt64(_ key: String) -> Int64? {
    let svc = agxService()
    if svc == 0 { return nil }
    defer { IOObjectRelease(svc) }
    guard let unmanaged = IORegistryEntryCreateCFProperty(svc, key as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    let raw = unmanaged.takeRetainedValue()
    guard CFGetTypeID(raw) == CFNumberGetTypeID() else { return nil }
    let num = raw as! CFNumber
    var value: Int64 = 0
    guard CFNumberGetValue(num, .sInt64Type, &value) else { return nil }
    return value
}

/// Current GPU power cap in mW.
func agxCurrentMaxMW() -> Int64? {
    agxReadInt64("MaxGPUAbsolutePower")
}

/// Set the GPU power cap. Returns the IOKit result (KERN_SUCCESS on success).
func agxSetCapMW(_ mw: Int64) -> kern_return_t {
    let svc = agxService()
    if svc == 0 { return KERN_FAILURE }
    defer { IOObjectRelease(svc) }
    let dict: [String: Any] = [
        "SetMaxGPUAbsolutePower": true,
        "AbsoluteTarget": mw,
    ]
    return IORegistryEntrySetCFProperties(svc, dict as CFDictionary)
}

// MARK: - JSON Protocol

struct ApplyRequest: Codable {
    let token: String
    let gpuCapMW: Int64?
    let op: String? // "status" | "restore" | "setDisableSleep" | "setStealth" | "exit" | nil = apply cap
    let enabled: Bool?
}

struct ApplyResponse: Codable {
    let success: Bool
    let message: String
    let origMaxMW: Int64?
    let maxCapMW: Int64?
    let sleepDisabled: Bool?
    let stealthEnabled: Bool?
}

// MARK: - Power policy

private let clamshellMessageID: UInt32 = 0xe003_4100

func readSleepDisabled() -> Bool? {
    let service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceNameMatching("IOPMrootDomain")
    )
    guard service != IO_OBJECT_NULL else { return nil }
    defer { IOObjectRelease(service) }

    guard let unmanaged = IORegistryEntryCreateCFProperty(
        service,
        "SleepDisabled" as CFString,
        kCFAllocatorDefault,
        0
    ) else { return nil }

    let value = unmanaged.takeRetainedValue()
    guard CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
    return CFBooleanGetValue(value as! CFBoolean)
}

func readClamshellClosed() -> Bool? {
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

func runPmset(_ arguments: [String]) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = arguments

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
        try process.run()
    } catch {
        return "failed to launch pmset: \(error.localizedDescription)"
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    guard process.terminationStatus == 0 else {
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "pmset exited with status \(process.terminationStatus)" : text
    }
    return nil
}

final class PowerPolicyController {
    struct Status {
        let disableSleep: Bool
        let stealth: Bool
    }

    private let lock = NSLock()
    private var disableSleepEnabled: Bool
    private var stealthEnabled = false
    private var ownsSleepDisabled = false
    private var clamshellObserverAvailable = false
    private var lastLidClosed: Bool?

    init() {
        disableSleepEnabled = readSleepDisabled() ?? false
    }

    func status() -> Status {
        lock.lock()
        defer { lock.unlock() }
        if let actual = readSleepDisabled(), actual != disableSleepEnabled {
            disableSleepEnabled = actual
        }
        return Status(
            disableSleep: disableSleepEnabled,
            stealth: stealthEnabled
        )
    }

    func setDisableSleep(_ enabled: Bool) -> (Status, String?) {
        lock.lock()
        defer { lock.unlock() }

        if enabled {
            guard let wasAlreadyDisabled = readSleepDisabled() else {
                return (statusLocked(), "Unable to read SleepDisabled")
            }
            if !wasAlreadyDisabled {
                if let error = runPmset(["-a", "disablesleep", "1"]) {
                    return (statusLocked(), error)
                }
            }
            guard readSleepDisabled() == true else {
                return (statusLocked(), "SleepDisabled did not become true")
            }
            disableSleepEnabled = true
            if !wasAlreadyDisabled { ownsSleepDisabled = true }
        } else {
            stealthEnabled = false
            if readSleepDisabled() == false {
                disableSleepEnabled = false
                ownsSleepDisabled = false
                return (statusLocked(), nil)
            }
            if let error = runPmset(["-a", "disablesleep", "0"]) {
                return (statusLocked(), error)
            }
            guard readSleepDisabled() == false else {
                return (statusLocked(), "SleepDisabled did not become false")
            }
            disableSleepEnabled = false
            ownsSleepDisabled = false
        }
        return (statusLocked(), nil)
    }

    func setClamshellObserverAvailable(_ available: Bool) {
        lock.lock()
        clamshellObserverAvailable = available
        if !available { stealthEnabled = false }
        lock.unlock()
    }

    func setStealth(_ enabled: Bool) -> (Status, String?) {
        lock.lock()
        defer { lock.unlock() }

        if enabled {
            guard clamshellObserverAvailable else {
                stealthEnabled = false
                return (statusLocked(), "Clamshell monitoring is unavailable")
            }
            guard disableSleepEnabled, readSleepDisabled() == true else {
                stealthEnabled = false
                return (statusLocked(), "Disable Sleep must be enabled first")
            }
        }
        stealthEnabled = enabled
        return (statusLocked(), nil)
    }

    func primeClamshellState(_ closed: Bool) {
        lock.lock()
        lastLidClosed = closed
        lock.unlock()
    }

    func handleClamshellClosed(_ closed: Bool) {
        lock.lock()
        defer { lock.unlock() }

        let wasClosed = lastLidClosed ?? false
        lastLidClosed = closed
        guard stealthEnabled else { return }

        if closed {
            // Re-arm the policy for every new close event. The previous
            // open event may have restored normal sleep before sleepnow.
            guard !wasClosed else { return }
            if readSleepDisabled() == true {
                disableSleepEnabled = true
                return
            }
            if let error = runPmset(["-a", "disablesleep", "1"]) {
                fputs("[helper] stealth failed to disable sleep on lid close: \(error)\n", stderr)
                return
            }
            guard readSleepDisabled() == true else {
                fputs("[helper] stealth could not verify sleep disabled on lid close\n", stderr)
                return
            }
            disableSleepEnabled = true
            ownsSleepDisabled = true
            return
        }

        // Fire only on a real closed -> open transition. Keep stealthEnabled
        // true so the next close/open cycle can arm and fire again.
        guard wasClosed else { return }
        guard disableSleepEnabled || readSleepDisabled() == true else { return }

        if let error = runPmset(["-a", "disablesleep", "0"]) {
            fputs("[helper] stealth failed to re-enable sleep: \(error)\n", stderr)
            return
        }
        guard readSleepDisabled() == false else {
            fputs("[helper] stealth could not verify sleep re-enabled\n", stderr)
            return
        }

        disableSleepEnabled = false
        ownsSleepDisabled = false

        if let error = runPmset(["sleepnow"]) {
            fputs("[helper] stealth sleepnow failed: \(error)\n", stderr)
        } else {
            fputs("[helper] stealth sleep requested after lid opened\n", stderr)
        }
    }

    func cleanup() {
        lock.lock()
        defer { lock.unlock() }

        stealthEnabled = false
        if ownsSleepDisabled {
            if let error = runPmset(["-a", "disablesleep", "0"]) {
                fputs("[helper] cleanup failed to re-enable sleep: \(error)\n", stderr)
            }
        }
        ownsSleepDisabled = false
        disableSleepEnabled = readSleepDisabled() ?? false
    }

    private func statusLocked() -> Status {
        Status(
            disableSleep: disableSleepEnabled,
            stealth: stealthEnabled
        )
    }
}

final class ClamshellObserver {
    private let policy: PowerPolicyController
    private let queue = DispatchQueue(label: "VolterHelper.Clamshell", qos: .userInitiated)
    private var port: OpaquePointer?
    private var notification: io_object_t = IO_OBJECT_NULL

    private let callback: IOServiceInterestCallback = { refCon, _, messageType, messageArgument in
        guard messageType == clamshellMessageID, let refCon else { return }
        let observer = Unmanaged<ClamshellObserver>
            .fromOpaque(refCon)
            .takeUnretainedValue()
        let bits = messageArgument.map { UInt(bitPattern: $0) } ?? 0
        observer.policy.handleClamshellClosed(
            (bits & UInt(kClamshellStateBit)) != 0
        )
    }

    init(policy: PowerPolicyController) {
        self.policy = policy
    }

    func start() -> IOReturn {
        guard port == nil else { return KERN_ALREADY_IN_SET }
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            return kIOReturnNoMemory
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
            return kIOReturnNotFound
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
        if result != KERN_SUCCESS {
            IONotificationPortDestroy(port)
            self.port = nil
            return result
        }

        // Register first, then take one snapshot on the same delivery queue.
        queue.sync {
            if let initialClosed = readClamshellClosed() {
                self.policy.primeClamshellState(initialClosed)
            }
        }
        return result
    }
}

let powerPolicy = PowerPolicyController()
let clamshellObserver = ClamshellObserver(policy: powerPolicy)

// MARK: - Socket helpers

func writeAll(fd: Int32, data: Data) -> Bool {
    var written = 0
    let total = data.count
    if total == 0 { return true }
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return false }
        while written < total {
            let n = write(fd, base.advanced(by: written), total - written)
            if n <= 0 { return false }
            written += n
        }
        return true
    }
}

func readAll(fd: Int32, count: Int) -> Data? {
    var buf = Data(count: count)
    var readSoFar = 0
    var success = false
    let ok = buf.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return false }
        while readSoFar < count {
            let n = read(fd, base.advanced(by: readSoFar), count - readSoFar)
            if n <= 0 { return false }
            readSoFar += n
        }
        return true
    }
    success = ok
    return success ? buf : nil
}

func writeFrame(fd: Int32, data: Data) -> Bool {
    var lenBE = UInt32(data.count).bigEndian
    let lenData = withUnsafeBytes(of: &lenBE) { Data($0) }
    if !writeAll(fd: fd, data: lenData) { return false }
    if data.count > 0 && !writeAll(fd: fd, data: data) { return false }
    return true
}

func readFrame(fd: Int32) -> Data? {
    guard let lenData = readAll(fd: fd, count: 4) else { return nil }
    let len = lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
    if len > 1024*1024 { return nil }
    if len == 0 { return Data() }
    return readAll(fd: fd, count: Int(len))
}

func sendResponse(fd: Int32, success: Bool, message: String) {
    let power = powerPolicy.status()
    let resp = ApplyResponse(
        success: success,
        message: message,
        origMaxMW: kDefaultMaxMW,
        maxCapMW: agxCurrentMaxMW(),
        sleepDisabled: power.disableSleep,
        stealthEnabled: power.stealth
    )
    if let data = try? JSONEncoder().encode(resp) {
        _ = writeFrame(fd: fd, data: data)
    }
    fputs("[helper] done success=\(success) \(message)\n", stderr)
}

// MARK: - Main

func printUsage() {
    fputs("Usage: VolterHelper --daemon --ppid <pid> --socket <path> --token <token>\n", stderr)
}

var socketPath: String?
var ppid: Int32 = 0
var token: String?

var idx = 1
while idx < CommandLine.arguments.count {
    let arg = CommandLine.arguments[idx]
    switch arg {
    case "--daemon": break
    case "--ppid":
        idx += 1; if idx < CommandLine.arguments.count { ppid = Int32(CommandLine.arguments[idx]) ?? 0 }
    case "--socket":
        idx += 1; if idx < CommandLine.arguments.count { socketPath = CommandLine.arguments[idx] }
    case "--token":
        idx += 1; if idx < CommandLine.arguments.count { token = CommandLine.arguments[idx] }
    default: break
    }
    idx += 1
}

guard let sockPath = socketPath, !sockPath.isEmpty, let expectedToken = token, !expectedToken.isEmpty else {
    printUsage()
    exit(1)
}
if ppid == 0 { ppid = getppid() }

// Hard "Max": 100W for all Apple Silicon instead of a live-read default.
// (A live read while capped returns the cap, not the default — never trust it.)
// Slightly above real defaults (M5 Pro ~99.3W); firmware treats it as uncapped.
let kDefaultMaxMW: Int64 = 100_000
var gpuCapChangedByVolter = false

do {
    let probe = agxService()
    if probe == 0 {
        fputs("[helper] WARNING: no AGX service at startup, will retry per request\n", stderr)
    } else {
        IOObjectRelease(probe)
        fputs("[helper] AGX GPU present, hard max \(kDefaultMaxMW) mW\n", stderr)
    }
}

func restoreDefaultCap() -> Bool {
    let kr = agxSetCapMW(kDefaultMaxMW)
    fputs("[helper] restore \(kDefaultMaxMW) mW -> 0x\(String(kr, radix: 16))\n", stderr)
    return kr == KERN_SUCCESS
}

// Setup signal handler to clean up socket
var globalSocketPathForCleanup = sockPath
func cleanupAndExit(_ code: Int32) -> Never {
    // Restore every Volter-owned policy before removing the helper endpoint.
    powerPolicy.cleanup()
    if gpuCapChangedByVolter {
        _ = restoreDefaultCap()
    }
    unlink(globalSocketPathForCleanup)
    exit(code)
}
// Signal handling via parent watchdog; socket removed in cleanupAndExit
// Keep SIGTERM handler simple using Swift's signal with global var
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

// Remove stale socket if present and not in use
if FileManager.default.fileExists(atPath: sockPath) {
    // Try to connect - if success, another helper is alive
    let probe = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    strncpy(&addr.sun_path.0, sockPath, MemoryLayout.size(ofValue: addr.sun_path) - 1)
    let ret = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            connect(probe, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    close(probe)
    if ret == 0 {
        fputs("[helper] another helper already running at \(sockPath), exiting\n", stderr)
        exit(0)
    } else {
        fputs("[helper] stale socket found, removing \(sockPath)\n", stderr)
        unlink(sockPath)
    }
}

// Create and bind socket
let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
if listenFD < 0 { perror("socket"); exit(1) }
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
strncpy(&addr.sun_path.0, sockPath, MemoryLayout.size(ofValue: addr.sun_path) - 1)
let bindRet = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        bind(listenFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
if bindRet != 0 { perror("bind"); close(listenFD); exit(1) }
if chmod(sockPath, 0o666) != 0 { perror("chmod") } // 0666 so user can connect (token protects)
if listen(listenFD, 5) != 0 { perror("listen"); close(listenFD); exit(1) }

fputs("[helper] listening on \(sockPath) ppid=\(ppid) token=\(expectedToken.prefix(6))***\n", stderr)

let clamshellResult = clamshellObserver.start()
powerPolicy.setClamshellObserverAvailable(clamshellResult == KERN_SUCCESS)
if clamshellResult != KERN_SUCCESS {
    fputs("[helper] clamshell observer unavailable: 0x\(String(clamshellResult, radix: 16))\n", stderr)
}

// Parent watchdog - exit when parent dies (cleanupAndExit restores the cap first)
DispatchQueue.global(qos: .background).async {
    while true {
        if kill(ppid, 0) != 0 {
            fputs("[helper] parent \(ppid) died, cleaning up\n", stderr)
            cleanupAndExit(0)
        }
        sleep(1)
    }
}

// Accept loop
while true {
    let clientFD = accept(listenFD, nil, nil)
    if clientFD < 0 {
        if errno == EINTR { continue }
        perror("accept")
        continue
    }
    // Peer credential check
    var uid: uid_t = 0
    var gid: gid_t = 0
    if getpeereid(clientFD, &uid, &gid) == 0 {
        if uid != getuid() && uid != 0 {
            fputs("[helper] peer uid=\(uid) gid=\(gid) (expected Volter user)\n", stderr)
        }
    }
    // Use timeout for read - set SO_RCVTIMEO
    var tv = timeval(tv_sec: 10, tv_usec: 0)
    setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    DispatchQueue.global().async {
        defer { close(clientFD) }
        guard let data = readFrame(fd: clientFD) else {
            fputs("[helper] readFrame failed\n", stderr)
            return
        }
        let decoder = JSONDecoder()
        guard let req = try? decoder.decode(ApplyRequest.self, from: data) else {
            fputs("[helper] decode failed \(String(data: data, encoding: .utf8) ?? "")\n", stderr)
            sendResponse(fd: clientFD, success: false, message: "invalid json")
            return
        }
        // Token check
        if req.token != expectedToken {
            fputs("[helper] token mismatch\n", stderr)
            sendResponse(fd: clientFD, success: false, message: "token mismatch")
            return
        }
        // Exit command (restores cap via cleanupAndExit)
        if req.op == "exit" {
            sendResponse(fd: clientFD, success: true, message: "bye")
            fputs("[helper] exit requested\n", stderr)
            cleanupAndExit(0)
        }
        // Status read (no writes)
        if req.op == "status" {
            let probe = agxService()
            if probe == 0 {
                sendResponse(fd: clientFD, success: false, message: "no AGX GPU found")
            } else {
                IOObjectRelease(probe)
                sendResponse(fd: clientFD, success: true, message: "ok")
            }
            return
        }
        // Disable Sleep policy
        if req.op == "setDisableSleep" {
            guard let enabled = req.enabled else {
                sendResponse(fd: clientFD, success: false, message: "missing enabled")
                return
            }
            let (status, error) = powerPolicy.setDisableSleep(enabled)
            if let error {
                sendResponse(fd: clientFD, success: false, message: error)
            } else {
                sendResponse(
                    fd: clientFD,
                    success: true,
                    message: status.disableSleep ? "sleep disabled" : "sleep enabled"
                )
            }
            return
        }
        // Stealth auto-sleep on lid reopen
        if req.op == "setStealth" {
            guard let enabled = req.enabled else {
                sendResponse(fd: clientFD, success: false, message: "missing enabled")
                return
            }
            let (_, error) = powerPolicy.setStealth(enabled)
            if let error {
                sendResponse(fd: clientFD, success: false, message: error)
            } else {
                sendResponse(
                    fd: clientFD,
                    success: true,
                    message: enabled ? "stealth enabled" : "stealth disabled"
                )
            }
            return
        }
        // Restore default cap
        if req.op == "restore" {
            if restoreDefaultCap() {
                gpuCapChangedByVolter = false
                sendResponse(fd: clientFD, success: true, message: "restored \(kDefaultMaxMW) mW")
            } else {
                sendResponse(fd: clientFD, success: false, message: "restore failed (no AGX GPU?)")
            }
            return
        }
        // Apply a new cap only when no named operation was requested.
        if req.op != nil {
            sendResponse(fd: clientFD, success: false, message: "unknown operation")
            return
        }
        guard let mw = req.gpuCapMW else {
            sendResponse(fd: clientFD, success: false, message: "missing gpuCapMW")
            return
        }
        fputs("[helper] apply gpuCap=\(mw) mW\n", stderr)
        if mw < kMinCapMW || mw > kDefaultMaxMW {
            sendResponse(fd: clientFD, success: false,
                         message: "cap must be \(kMinCapMW)...\(kDefaultMaxMW) mW")
            return
        }
        let kr = agxSetCapMW(mw)
        if kr != KERN_SUCCESS {
            sendResponse(fd: clientFD, success: false,
                         message: "AGX write failed 0x\(String(kr, radix: 16))")
            return
        }
        // Verify the firmware took it.
        if let back = agxCurrentMaxMW(), back != mw {
            sendResponse(fd: clientFD, success: false,
                         message: "verify mismatch: wrote \(mw) mW, reads \(back) mW")
            return
        }
        gpuCapChangedByVolter = true
        sendResponse(fd: clientFD, success: true, message: "capped \(mw) mW")
    }
}
