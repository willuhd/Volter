//
//  PrivilegedHelperManager.swift
//  Volter - Manages the root helper daemon (Approach 2)
//  One Touch ID per app launch. No repeated prompts.
//

import Foundation
import AppKit

final class PrivilegedHelperManager {
    static let shared = PrivilegedHelperManager()
    
    private let token: String
    private let socketDir: String
    private let socketPath: String
    private var tokenGeneratedAt = Date()
    
    private init() {
        self.token = UUID().uuidString
        // Use per-user temp dir with 0700 - matches helper's expectation
        // /tmp/volter-<uid>/helper.sock is simple and matches helper's mkdir 0700
        let uid = getuid()
        self.socketDir = "/tmp/volter-\(uid)"
        self.socketPath = "\(socketDir)/helper.sock"
    }
    
    // MARK: - Helper binary location
    
    private func helperPath() -> String? {
        // 1. Inside app bundle Resources (production: after CopyFiles phase)
        if let p = Bundle.main.path(forResource: "VolterHelper", ofType: nil), FileManager.default.fileExists(atPath: p) {
            return p
        }
        // 2. Next to main executable (some configs)
        let exeDir = (Bundle.main.executablePath as NSString?)?.deletingLastPathComponent ?? ""
        let candidate2 = (exeDir as NSString).appendingPathComponent("VolterHelper")
        if FileManager.default.fileExists(atPath: candidate2) { return candidate2 }
        // 3. Resources sibling of executable: .../Volter.app/Contents/Resources/VolterHelper
        let candidate3 = ((exeDir as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Resources/VolterHelper")
        if FileManager.default.fileExists(atPath: candidate3) { return candidate3 }
        // 4. DerivedData fallback for Debug (xcodebuild without copy phase)
        // Try to locate via xcode derived data - search common location
        // This lets `xcodebuild -scheme Volter` work even before CopyFiles is added
        let derived = "/Users/\(NSUserName())/Library/Developer/Xcode/DerivedData"
        // We do a simple glob: find VolterHelper in DerivedData/Build/Products/Debug
        // Avoid expensive search - just check Expected path
        if let derivedHelper = findDerivedHelper() { return derivedHelper }
        return nil
    }
    
    private func findDerivedHelper() -> String? {
        let fm = FileManager.default
        let derivedBase = "/Users/\(NSUserName())/Library/Developer/Xcode/DerivedData"
        guard let contents = try? fm.contentsOfDirectory(atPath: derivedBase) else { return nil }
        for entry in contents where entry.hasPrefix("Volter-") {
            let p = "\(derivedBase)/\(entry)/Build/Products/Debug/VolterHelper"
            if fm.fileExists(atPath: p) { return p }
            let p2 = "\(derivedBase)/\(entry)/Build/Products/Release/VolterHelper"
            if fm.fileExists(atPath: p2) { return p2 }
        }
        return nil
    }
    
    // MARK: - Socket helpers (must match VolterHelper's framing)
    
    private func writeAll(fd: Int32, data: Data) -> Bool {
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
    
    private func readAll(fd: Int32, count: Int) -> Data? {
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
    
    private func writeFrame(fd: Int32, data: Data) -> Bool {
        var lenBE = UInt32(data.count).bigEndian
        let lenData = withUnsafeBytes(of: &lenBE) { Data($0) }
        if !writeAll(fd: fd, data: lenData) { return false }
        if data.count > 0 && !writeAll(fd: fd, data: data) { return false }
        return true
    }
    
    private func readFrame(fd: Int32) -> Data? {
        guard let lenData = readAll(fd: fd, count: 4) else { return nil }
        let len = lenData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        if len > 1024*1024 { return nil }
        if len == 0 { return Data() }
        return readAll(fd: fd, count: Int(len))
    }
    
    private func canConnect() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = socketPath
        strncpy(&addr.sun_path.0, path, MemoryLayout.size(ofValue: addr.sun_path)-1)
        let ret = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return ret == 0
    }
    
    private func waitForSocket(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if canConnect() { return true }
            usleep(100_000) // 0.1s
        }
        return false
    }
    
    // MARK: - Ensure helper running (triggers Touch ID once)
    
    @discardableResult
    func ensureHelper() -> Bool {
        if canConnect() { return true }
        // Clean stale socket if probe failed but file exists
        if FileManager.default.fileExists(atPath: socketPath) && !canConnect() {
            try? FileManager.default.removeItem(atPath: socketPath)
        }
        guard let helper = helperPath() else {
            print("[Volter] VolterHelper not found in bundle or DerivedData. Add Copy Files phase.")
            return false
        }
        // Ensure helper is executable
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper)
        // Pre-create socket dir as user so root helper's 0755 dir is traversable (fixes 0700 root bug)
        try? FileManager.default.createDirectory(atPath: socketDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        
        let ppid = getpid()
        // Escape single quotes in paths
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
        let helperEsc = esc(helper)
        let sockEsc = esc(socketPath)
        let tokenEsc = esc(token)
        // Launch as root via AppleScript (one Touch ID prompt)
        let script = "do shell script \"'\(helperEsc)' --daemon --ppid \(ppid) --socket '\(sockEsc)' --token '\(tokenEsc)' > /dev/null 2>&1 &\" with administrator privileges"
        var error: NSDictionary?
        if let appleScript = NSAppleScript(source: script) {
            let result = appleScript.executeAndReturnError(&error)
            if let err = error {
                print("[Volter] AppleScript error: \(err) result: \(result)")
                return false
            }
        } else {
            print("[Volter] NSAppleScript init failed")
            return false
        }
        // Wait for socket
        if waitForSocket(timeout: 2.0) {
            return true
        } else {
            return false
        }
    }
    
    // MARK: - Public API (replaces PowerManager's AuthorizationExecuteWithPrivileges)
    
    struct HelperRequest: Codable {
        let token: String
        let turbo: Bool?
        let powerLimit: Double?
        let lowPowerMode: String?
        let fanSpeed: Double?
        let op: String?
    }
    struct HelperResponse: Codable {
        let success: Bool
        let message: String
    }
    
    func apply(turbo: Bool, powerLimit: Double, lowPowerMode: String, fanSpeed: Double) -> Bool {
        let ok = ensureHelper()
        if !ok { return false }
        let req = HelperRequest(token: token, turbo: turbo, powerLimit: powerLimit, lowPowerMode: lowPowerMode, fanSpeed: fanSpeed, op: nil)
        guard let reqData = try? JSONEncoder().encode(req) else { return false }
        return send(reqData: reqData)
    }
    
    func terminateHelper() {
        // Best-effort send exit command; helper also exits when ppid dies
        let req = HelperRequest(token: token, turbo: nil, powerLimit: nil, lowPowerMode: nil, fanSpeed: nil, op: "exit")
        if let data = try? JSONEncoder().encode(req), canConnect() {
            _ = send(reqData: data, timeout: 1.0)
        }
        // Clean stale socket file (helper will also unlink)
        try? FileManager.default.removeItem(atPath: socketPath)
    }
    
    private func send(reqData: Data, timeout: TimeInterval = 10) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        strncpy(&addr.sun_path.0, socketPath, MemoryLayout.size(ofValue: addr.sun_path)-1)
        let ret = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ret != 0 {
            print("[Volter] connect failed \(String(cString: strerror(errno)))")
            return false
        }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if !writeFrame(fd: fd, data: reqData) {
            print("[Volter] writeFrame failed")
            return false
        }
        guard let respData = readFrame(fd: fd) else {
            print("[Volter] readFrame failed")
            return false
        }
        guard let resp = try? JSONDecoder().decode(HelperResponse.self, from: respData) else {
            print("[Volter] decode response failed \(String(data: respData, encoding: .utf8) ?? "")")
            return false
        }
        return resp.success
    }
    
    // For debugging
    func debugInfo() -> String {
        return "socket=\(socketPath) token=\(token.prefix(6))*** helper=\(helperPath() ?? "not found") canConnect=\(canConnect())"
    }
}
