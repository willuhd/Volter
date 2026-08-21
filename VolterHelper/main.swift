//
//  main.swift
//  VolterHelper - Privileged helper daemon (runs as root)
//  Approach 2: Spawn a Root Worker on App Startup - one Touch ID per launch
//
//  No Apple Developer certificate required.
//  Comunicates via Unix Domain Socket with token auth.
//

import Foundation
import IOKit
import Darwin

// MARK: - Constants

let kAnVMSRClassName = "VoltageShiftAnVMSR"
let kSecureDir = "/Library/Application Support/Volter"
var didSetupSecureDir = false

// MARK: - IOKit MSR Struct (must match kext)

struct MSRInOut {
    var action: UInt32 = 0
    var msr: UInt32 = 0
    var param: UInt64 = 0
}

let kActionRDMSR: UInt32 = 0
let kActionWRMSR: UInt32 = 1

// MARK: - JSON Protocol

struct ApplyRequest: Codable {
    let token: String
    let turbo: Bool?
    let powerLimit: Double?
    let lowPowerMode: String?
    let fanSpeed: Double?
    let op: String? // "exit" or nil = apply
}

struct ApplyResponse: Codable {
    let success: Bool
    let message: String
}

// MARK: - IOKit Helpers

func getService() -> io_service_t {
    var masterPort: mach_port_t = 0
    // IOMainPort is preferred on 12+, fallback to kIOMainPortDefault
    var ret = IOMainPort(mach_port_t(MACH_PORT_NULL), &masterPort)
    if ret != KERN_SUCCESS {
        ret = IOMainPort(kIOMainPortDefault, &masterPort)
        if ret != KERN_SUCCESS {
            fputs("[helper] IOMainPort failed: \(ret)\n", stderr)
            return 0
        }
    }
    var iter: io_iterator_t = 0
    ret = IOServiceGetMatchingServices(masterPort, IOServiceMatching(kAnVMSRClassName), &iter)
    if ret != KERN_SUCCESS {
        // not running is not an error - caller will load kext
        return 0
    }
    let service = IOIteratorNext(iter)
    IOObjectRelease(iter)
    if service == 0 { return 0 }
    // Optional path check
    var path = [CChar](repeating: 0, count: 512)
    _ = IORegistryEntryGetPath(service, kIOServicePlane, &path)
    return service
}

func kextStatIsLoaded() -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/kextstat")
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8) ?? ""
        return out.contains("VoltageShift")
    } catch {
        return false
    }
}

func runProcess(_ path: String, _ args: [String]) -> (Int32, String) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: path)
    task.arguments = args
    let pipe = Pipe()
    let errPipe = Pipe()
    task.standardOutput = pipe
    task.standardError = errPipe
    do {
        try task.run()
        task.waitUntilExit()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (task.terminationStatus, out + err)
    } catch {
        return (-1, "\(error)")
    }
}

func helperResourcesDir() -> String {
    // Helper is at Volter.app/Contents/Resources/VolterHelper
    // Resources dir is parent of helper binary
    let execPath = CommandLine.arguments[0]
    let execURL = URL(fileURLWithPath: execPath)
    let dir = execURL.deletingLastPathComponent().path
    // If launched via xcode build dir (DerivedData), helper's dir may be Products dir, not Resources
    // Fallback: also check Bundle.main
    if FileManager.default.fileExists(atPath: dir + "/VoltageShift.kext") {
        return dir
    }
    if let bundleResources = Bundle.main.resourcePath, FileManager.default.fileExists(atPath: bundleResources + "/VoltageShift.kext") {
        return bundleResources
    }
    // Last fallback: try Volter.app Resources relative to exec
    // Helper in .../Volter.app/Contents/MacOS/VolterHelper? but we put in Resources
    return dir
}

func ensureSecureDir() -> Bool {
    // Fast path: already set up and kext still loaded + smc present -> no XProtect/kernelmanagerd work
    if didSetupSecureDir && kextStatIsLoaded() && FileManager.default.fileExists(atPath: kSecureDir + "/smc") && FileManager.default.fileExists(atPath: kSecureDir + "/VoltageShift.kext") {
        return true
    }
    let fm = FileManager.default
    let resourcesDir = helperResourcesDir()
    fputs("[helper] resourcesDir: \(resourcesDir)\n", stderr)
    // 1. mkdir -p secureDir
    do {
        try fm.createDirectory(atPath: kSecureDir, withIntermediateDirectories: true, attributes: [FileAttributeKey.posixPermissions: 0o755])
    } catch {
        fputs("[helper] mkdir failed: \(error)\n", stderr)
        return false
    }
    // 2. copy smc and kext only if missing (avoid rewriting kext bundle every Apply which triggers XProtect)
    let items: [(src: String, dst: String)] = [
        (resourcesDir + "/smc", kSecureDir + "/smc"),
        (resourcesDir + "/VoltageShift.kext", kSecureDir + "/VoltageShift.kext"),
    ]
    var didCopy = false
    for item in items {
        if fm.fileExists(atPath: item.dst) {
            // Already there from first setup — skip copy/chown to avoid XProtect scan
            continue
        }
        if fm.fileExists(atPath: item.src) {
            do {
                try fm.copyItem(atPath: item.src, toPath: item.dst)
                didCopy = true
            } catch {
                // cp -Rf for kext directory
                let (_, out) = runProcess("/bin/cp", ["-Rf", item.src, item.dst])
                if fm.fileExists(atPath: item.dst) {
                    didCopy = true
                } else {
                    fputs("[helper] copy \(item.src) -> \(item.dst) failed: \(error) \(out)\n", stderr)
                }
            }
        } else {
            fputs("[helper] source not found: \(item.src)\n", stderr)
            if !fm.fileExists(atPath: item.dst) && item.dst.contains("VoltageShift") {
                fputs("[helper] KEXT missing and source missing\n", stderr)
                return false
            }
        }
    }
    // 3. chown root:wheel and chmod 755 only if we copied something
    if didCopy {
        _ = runProcess("/usr/sbin/chown", ["-R", "root:wheel", kSecureDir])
        _ = runProcess("/bin/chmod", ["-R", "755", kSecureDir])
    }
    // 4. kext load if needed
    if !kextStatIsLoaded() {
        fputs("[helper] kext not loaded, loading...\n", stderr)
        // try kextutil first (more verbose, handles -r)
        let resDir = helperResourcesDir()
        var (status, out) = runProcess("/usr/bin/kextutil", ["-q", "-r", resDir, "-b", "com.sicreative.VoltageShift", kSecureDir + "/VoltageShift.kext"])
        if status != 0 {
            fputs("[helper] kextutil failed \(status) \(out), trying kextload\n", stderr)
            (status, out) = runProcess("/sbin/kextload", [kSecureDir + "/VoltageShift.kext"])
            fputs("[helper] kextload \(status) \(out)\n", stderr)
            if status != 0 {
                // Try fixing perms again and retry
                _ = runProcess("/usr/sbin/chown", ["-R", "root:wheel", kSecureDir + "/VoltageShift.kext"])
                _ = runProcess("/bin/chmod", ["-R", "755", kSecureDir + "/VoltageShift.kext"])
                (status, out) = runProcess("/sbin/kextload", [kSecureDir + "/VoltageShift.kext"])
                if status != 0 {
                    fputs("[helper] kextload retry failed \(status) \(out)\n", stderr)
                    // Don't return false yet - IOService may still appear after a moment
                }
            }
        } else {
            fputs("[helper] kextutil success\n", stderr)
        }
        // Wait a bit for service to appear
        for _ in 0..<10 {
            if getService() != 0 { break }
            usleep(200_000)
        }
    } else {
        fputs("[helper] kext already loaded\n", stderr)
    }
    didSetupSecureDir = true
    return true
}

// MARK: - MSR Operations via IOKit

func withIOConnection<T>(_ body: (io_connect_t) throws -> T) -> T? {
    let service = getService()
    if service == 0 {
        fputs("[helper] getService() returned 0, trying ensureSecureDir+load\n", stderr)
        if !ensureSecureDir() {
            return nil
        }
        // retry
        let service2 = getService()
        if service2 == 0 {
            fputs("[helper] still no service after load\n", stderr)
            return nil
        }
        var connect: io_connect_t = 0
        let ret = IOServiceOpen(service2, mach_task_self_, 0, &connect)
        IOObjectRelease(service2)
        if ret != KERN_SUCCESS {
            fputs("[helper] IOServiceOpen failed \(ret)\n", stderr)
            return nil
        }
        defer { IOServiceClose(connect) }
        do {
            return try body(connect)
        } catch {
            fputs("[helper] body error \(error)\n", stderr)
            return nil
        }
    }
    var connect: io_connect_t = 0
    let ret = IOServiceOpen(service, mach_task_self_, 0, &connect)
    IOObjectRelease(service)
    if ret != KERN_SUCCESS {
        fputs("[helper] IOServiceOpen failed \(ret)\n", stderr)
        return nil
    }
    defer { IOServiceClose(connect) }
    do {
        return try body(connect)
    } catch {
        fputs("[helper] body error \(error)\n", stderr)
        return nil
    }
}

func rdmsr(connect: io_connect_t, msr: UInt32) -> UInt64? {
    var input = MSRInOut(action: kActionRDMSR, msr: msr, param: 0)
    var output = MSRInOut()
    var outSize = MemoryLayout<MSRInOut>.size
    let ret = withUnsafePointer(to: &input) { inPtr in
        withUnsafeMutablePointer(to: &output) { outPtr in
            IOConnectCallStructMethod(connect, UInt32(kActionRDMSR),
                                      inPtr, MemoryLayout<MSRInOut>.size,
                                      outPtr, &outSize)
        }
    }
    if ret != KERN_SUCCESS {
        fputs("[helper] RDMSR 0x\(String(msr, radix:16)) failed \(ret)\n", stderr)
        return nil
    }
    return output.param
}

func wrmsr(connect: io_connect_t, msr: UInt32, value: UInt64) -> Bool {
    var input = MSRInOut(action: kActionWRMSR, msr: msr, param: value)
    var output = MSRInOut()
    var outSize = MemoryLayout<MSRInOut>.size
    let ret = withUnsafePointer(to: &input) { inPtr in
        withUnsafeMutablePointer(to: &output) { outPtr in
            IOConnectCallStructMethod(connect, UInt32(kActionWRMSR),
                                      inPtr, MemoryLayout<MSRInOut>.size,
                                      outPtr, &outSize)
        }
    }
    if ret != KERN_SUCCESS {
        fputs("[helper] WRMSR 0x\(String(msr, radix:16))=0x\(String(value, radix:16)) failed \(ret)\n", stderr)
        return false
    }
    return true
}

func setTurbo(enable: Bool) -> Bool {
    guard let ok = withIOConnection({ connect -> Bool in
        guard let val = rdmsr(connect: connect, msr: 0x1a0) else { return false }
        let isDisabled = ((val >> 38) & 0x1) == 1
        fputs("[helper] current turbo disabled=\(isDisabled) val=0x\(String(val, radix:16))\n", stderr)
        var newVal = val
        if enable {
            newVal &= ~((UInt64(1) << 38))
        } else {
            newVal |= (UInt64(1) << 38)
        }
        if newVal == val {
            fputs("[helper] turbo already \(enable ? "enabled" : "disabled")\n", stderr)
            return true
        }
        return wrmsr(connect: connect, msr: 0x1a0, value: newVal)
    }) else { return false }
    return ok
}

func setPowerLimit(plWatts: Int) -> Bool {
    if plWatts <= 0 { return true } // 0 means don't touch
    let p1 = plWatts * 8
    let p2 = plWatts * 8 // Volter currently sets PL1=PL2
    guard let ok = withIOConnection({ connect -> Bool in
        guard let cur = rdmsr(connect: connect, msr: 0x610) else { return false }
        let p1cur = (cur & 0x7FFF)
        let p2cur = ((cur >> 32) & 0x7FFF)
        fputs("[helper] current PL1=\(p1cur/8)W PL2=\(p2cur/8)W raw=0x\(String(cur, radix:16))\n", stderr)
        if p1 < 5*8 || p2 < 5*8 {
            fputs("[helper] power too low\n", stderr)
            return false
        }
        var newVal = cur
        // Volter uses bits 0..14 and 32..46
        for i in 0..<15 {
            let bit: UInt64 = UInt64((p1 >> i) & 0x1)
            let mask: UInt64 = UInt64(1) << i
            if bit == 1 { newVal |= mask } else { newVal &= ~mask }
        }
        for i in 32..<47 {
            let p2bit = (p2 >> (i-32)) & 0x1
            let mask: UInt64 = UInt64(1) << i
            if p2bit == 1 { newVal |= mask } else { newVal &= ~mask }
        }
        fputs("[helper] write 0x610 0x\(String(newVal, radix:16)) (was 0x\(String(cur, radix:16)))\n", stderr)
        return wrmsr(connect: connect, msr: 0x610, value: newVal)
    }) else { return false }
    return ok
}

// MARK: - SMC / pmset via Process (helper is root, so no sudo needed)

func fanSpeedToHex(_ rpm: Int) -> String {
    let f = Float(rpm)
    let bits = f.bitPattern
    let b0 = UInt8(bits & 0xFF)
    let b1 = UInt8((bits >> 8) & 0xFF)
    let b2 = UInt8((bits >> 16) & 0xFF)
    let b3 = UInt8((bits >> 24) & 0xFF)
    return String(format: "%02x%02x%02x%02x", b0, b1, b2, b3)
}

func setFan(rpm: Int) -> Bool {
    let smcPath = kSecureDir + "/smc"
    var path = smcPath
    if !FileManager.default.fileExists(atPath: path) {
        // fallback to bundled smc in resources dir
        path = helperResourcesDir() + "/smc"
    }
    if !FileManager.default.fileExists(atPath: path) {
        fputs("[helper] smc not found at \(path)\n", stderr)
        return false
    }
    if rpm > 0 {
        let hex = fanSpeedToHex(rpm)
        let (s1, o1) = runProcess(path, ["-k", "F0Md", "-w", "01"])
        fputs("[helper] smc F0Md 01 -> \(s1) \(o1)\n", stderr)
        let (s2, o2) = runProcess(path, ["-k", "F0Tg", "-w", hex])
        fputs("[helper] smc F0Tg \(hex) -> \(s2) \(o2)\n", stderr)
        return s1 == 0 && s2 == 0
    } else {
        let (s, o) = runProcess(path, ["-k", "F0Md", "-w", "00"])
        fputs("[helper] smc F0Md 00 -> \(s) \(o)\n", stderr)
        return s == 0
    }
}

func setLowPowerMode(_ mode: String) -> Bool {
    let pmset = "/usr/bin/pmset"
    var status: Int32 = 0
    var out = ""
    switch mode {
    case "On":
        (status, out) = runProcess(pmset, ["-a", "lowpowermode", "1"])
    case "Battery":
        let (s1, o1) = runProcess(pmset, ["-b", "lowpowermode", "1"])
        let (s2, o2) = runProcess(pmset, ["-c", "lowpowermode", "0"])
        fputs("[helper] pmset battery \(s1) \(o1) \(s2) \(o2)\n", stderr)
        return s1 == 0 && s2 == 0
    default: // Off
        (status, out) = runProcess(pmset, ["-a", "lowpowermode", "0"])
    }
    fputs("[helper] pmset \(mode) -> \(status) \(out)\n", stderr)
    return status == 0
}

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

// Setup signal handler to clean up socket
var globalSocketPathForCleanup = sockPath
func cleanupAndExit(_ code: Int32) -> Never {
    unlink(globalSocketPathForCleanup)
    // Try to remove parent dir if empty and is our volter-xxx dir
    let dir = (globalSocketPathForCleanup as NSString).deletingLastPathComponent
    if dir.contains("volter-") {
        rmdir(dir)
    }
    exit(code)
}
// Signal handling via parent watchdog; socket removed in cleanupAndExit
// Keep SIGTERM handler simple using Swift's signal with global var
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

// Ensure parent dir exists - 0755 when created as root so user can traverse (token protects)
let sockDir = (sockPath as NSString).deletingLastPathComponent
do {
    try FileManager.default.createDirectory(atPath: sockDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    chmod(sockDir, 0o755)
} catch {
    fputs("[helper] mkdir sockDir failed \(error)\n", stderr)
    exit(1)
}
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

// Ensure secure dir and kext loaded upfront (so first request is fast)
if !ensureSecureDir() {
    fputs("[helper] ensureSecureDir failed at startup (will retry per request)\n", stderr)
}

// Parent watchdog - exit when parent dies
DispatchQueue.global(qos: .background).async {
    while true {
        if kill(ppid, 0) != 0 {
            fputs("[helper] parent \(ppid) died, cleaning up\n", stderr)
            cleanupAndExit(0)
        }
        // Also check if parent pid was reused? Check parent is still same? Not critical for session daemon
        sleep(1)
    }
}

// Make listen socket non-blocking? Keep blocking but accept loop handles
// Set timeout via dispatch?

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
            // Allow root and the user who launched Volter
            // getuid() here is 0 (root), so we need to compare to expected user's uid?
            // Helper is root, getuid()==0, so check client uid matches parent's uid
            // parent's uid = uid of ppid's user - easiest: allow any uid that is not 0 but we log
            // Actually helper is root, getuid()==0, so the check uid != 0 will pass for normal user
            // We want to allow the Volter user's uid only - get parent's uid via stat on /proc? Simpler: allow uid == 501 etc
            // We'll just log and continue, but require token anyway
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
            let resp = ApplyResponse(success: false, message: "invalid json")
            if let respData = try? JSONEncoder().encode(resp) { _ = writeFrame(fd: clientFD, data: respData) }
            return
        }
        // Token check
        if req.token != expectedToken {
            fputs("[helper] token mismatch\n", stderr)
            let resp = ApplyResponse(success: false, message: "token mismatch")
            if let respData = try? JSONEncoder().encode(resp) { _ = writeFrame(fd: clientFD, data: respData) }
            return
        }
        // Exit command
        if req.op == "exit" {
            let resp = ApplyResponse(success: true, message: "bye")
            if let respData = try? JSONEncoder().encode(resp) { _ = writeFrame(fd: clientFD, data: respData) }
            fputs("[helper] exit requested\n", stderr)
            cleanupAndExit(0)
        }
        // Apply flow
        fputs("[helper] apply turbo=\(String(describing:req.turbo)) power=\(String(describing:req.powerLimit)) fan=\(String(describing:req.fanSpeed)) lpm=\(String(describing:req.lowPowerMode))\n", stderr)
        // Ensure secure dir again
        if !ensureSecureDir() {
            let resp = ApplyResponse(success: false, message: "secure dir setup failed")
            if let d = try? JSONEncoder().encode(resp) { _ = writeFrame(fd: clientFD, data: d) }
            return
        }
        var success = true
        var messages: [String] = []
        if let turbo = req.turbo {
            let ok = setTurbo(enable: turbo)
            success = success && ok
            messages.append("turbo=\(ok)")
        }
        if let pl = req.powerLimit, pl > 0 {
            let ok = setPowerLimit(plWatts: Int(pl))
            success = success && ok
            messages.append("power=\(ok)")
        }
        if let fan = req.fanSpeed {
            let ok = setFan(rpm: Int(fan))
            success = success && ok
            messages.append("fan=\(ok)")
        }
        if let lpm = req.lowPowerMode {
            let ok = setLowPowerMode(lpm)
            success = success && ok
            messages.append("lpm=\(ok)")
        }
        let resp = ApplyResponse(success: success, message: messages.joined(separator: ", "))
        if let respData = try? JSONEncoder().encode(resp) {
            _ = writeFrame(fd: clientFD, data: respData)
        }
        fputs("[helper] done success=\(success)\n", stderr)
    }
}
