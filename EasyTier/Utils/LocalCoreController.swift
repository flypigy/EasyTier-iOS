#if os(macOS)
import CryptoKit
import Foundation
import EasyTierShared
import os

/// Runs the standalone EasyTier core as a root LaunchDaemon so the app can
/// bring up the tunnel without NetworkExtension entitlements.
///
/// The daemon (installed once via an administrator authorization prompt)
/// supervises a watcher script that starts/stops `easytier-core` based on a
/// config file inside an app-writable directory, so later connects and
/// disconnects never require elevated privileges.
nonisolated final class LocalCoreController: @unchecked Sendable {
    static let shared = LocalCoreController()

    private static let logger = Logger(subsystem: APP_BUNDLE_ID, category: "LocalCore")

    private static let installDir = "/Library/Application Support/EasyTier"
    private static let daemonLabel = "cn.easytier.core"
    private static let daemonPlistPath = "/Library/LaunchDaemons/cn.easytier.core.plist"
    private static let watchScriptName = "core-watch.sh"
    private static let binaryName = "easytier-core"
    private static let maxLogBytes = 10 * 1024 * 1024
    private static let startTimeoutSeconds = 30.0

    enum LocalCoreError: LocalizedError {
        case coreBinaryMissing
        case optionsMissing
        case configEmpty
        case startTimeout(String?)
        case logUnavailable
        case installCancelled
        case installFailed(String)
        case processFailed(status: Int, stderr: String)

        var errorDescription: String? {
            switch self {
            case .coreBinaryMissing:
                return "easytier-core binary is missing from the app bundle"
            case .optionsMissing:
                return "no tunnel options saved, save a profile before connecting"
            case .configEmpty:
                return "tunnel options contain an empty core config"
            case .startTimeout(let log):
                return "easytier-core did not start within timeout\(log.map { ": \($0)" } ?? "")"
            case .logUnavailable:
                return "core log is unavailable"
            case .installCancelled:
                return "local core service installation was cancelled"
            case .installFailed(let message):
                return "failed to install local core service: \(message)"
            case .processFailed(let status, let stderr):
                return "command exited with status \(status): \(stderr)"
            }
        }
    }

    struct CoreState: Codable {
        var running: Bool?
        var pid: Int?
        var startedAt: Double?
        var exitCode: Int?
        var updatedAt: Double?
    }

    /// App-writable directory shared with the root watcher (config in, state out).
    let stateDir: URL
    /// Same file the app's log viewer tails (app group container / easytier.log).
    let logURL: URL

    private var configURL: URL { stateDir.appendingPathComponent("config.toml") }
    private var stateURL: URL { stateDir.appendingPathComponent("core-state.json") }
    private var bundledBinaryURL: URL? {
        Bundle.main.url(forResource: Self.binaryName, withExtension: nil)
    }
    private var installedBinaryURL: URL {
        URL(fileURLWithPath: Self.installDir).appendingPathComponent(Self.binaryName)
    }

    init() {
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: APP_GROUP_ID
        )
        let base = container
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let dir = base?.appendingPathComponent("LocalCore", isDirectory: true)
        if let dir {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            stateDir = dir
        } else {
            stateDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("EasyTierLocalCore", isDirectory: true)
            try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        }
        logURL = base?.appendingPathComponent(LOG_FILENAME)
            ?? stateDir.appendingPathComponent(LOG_FILENAME)
    }

    // MARK: - Connection

    func connect() async throws {
        try await ensureInstalled()
        let config = Self.currentTunnelConfig() ?? ""
        guard !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCoreError.configEmpty
        }
        Self.logger.info("connect(): writing core config")
        try config.write(to: configURL, atomically: true, encoding: .utf8)

        let deadline = Date().addingTimeInterval(Self.startTimeoutSeconds)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(0.5))
            if isCoreRunning() {
                Self.logger.info("connect(): core is running")
                return
            }
        }
        throw LocalCoreError.startTimeout(logTail())
    }

    func disconnect() async {
        Self.logger.info("disconnect(): removing core config")
        try? FileManager.default.removeItem(at: configURL)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, isCoreRunning() {
            try? await Task.sleep(for: .seconds(0.5))
        }
    }

    // MARK: - Status

    func currentState() -> CoreState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CoreState.self, from: data)
    }

    func isCoreRunning(state: CoreState? = nil) -> Bool {
        let current = state ?? currentState()
        if let running = current?.running {
            return running
        }
        return isProcessAlive()
    }

    private func isProcessAlive() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-x", Self.binaryName]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Log

    func logTail(maxLines: Int = 40) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let tailBytes: UInt64 = 65536
        if let size = try? handle.seekToEnd(), size > tailBytes {
            try? handle.seek(toOffset: size - tailBytes)
        }
        guard let data = try? handle.readToEnd() else { return nil }
        var lines = String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init) ?? []
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        return lines.joined(separator: "\n")
    }

    func clearLog() throws {
        // The log may be owned by root when the watcher created it, so recreate
        // instead of truncating in place.
        try? FileManager.default.removeItem(at: logURL)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
    }

    func exportLogURL() throws -> URL {
        guard FileManager.default.fileExists(atPath: logURL.path) else {
            throw LocalCoreError.logUnavailable
        }
        return logURL
    }

    // MARK: - Service installation

    func ensureInstalled() async throws {
        guard let bundled = bundledBinaryURL else {
            throw LocalCoreError.coreBinaryMissing
        }
        let installed = FileManager.default.fileExists(atPath: installedBinaryURL.path)
            && FileManager.default.fileExists(atPath: Self.daemonPlistPath)
        if installed {
            let sameBinary = (try? Self.sha256(of: installedBinaryURL))
                == (try? Self.sha256(of: bundled))
            if sameBinary {
                return
            }
            Self.logger.info("bundled core binary changed, reinstalling service")
        }
        try await installService(bundledBinary: bundled)
    }

    private func installService(bundledBinary: URL) async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyTierInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let scriptURL = staging.appendingPathComponent(Self.watchScriptName)
        try Self.watchScript
            .replacingOccurrences(of: "__CONFIG_FILE__", with: configURL.path)
            .replacingOccurrences(of: "__LOG_FILE__", with: logURL.path)
            .replacingOccurrences(of: "__STATE_FILE__", with: stateURL.path)
            .write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path
        )

        let plistURL = staging.appendingPathComponent("\(Self.daemonLabel).plist")
        try Self.daemonPlist.write(to: plistURL, atomically: true, encoding: .utf8)

        let scriptPath = "\(Self.installDir)/\(Self.watchScriptName)"
        let shell = [
            "mkdir -p '\(Self.installDir)'",
            "cp -f '\(bundledBinary.path)' '\(installedBinaryURL.path)'",
            "cp -f '\(scriptURL.path)' '\(scriptPath)'",
            "cp -f '\(plistURL.path)' '\(Self.daemonPlistPath)'",
            "chown root:wheel '\(installedBinaryURL.path)' '\(scriptPath)' '\(Self.daemonPlistPath)'",
            "chmod 755 '\(installedBinaryURL.path)' '\(scriptPath)'",
            "chmod 644 '\(Self.daemonPlistPath)'",
            "launchctl bootout system/\(Self.daemonLabel) >/dev/null 2>&1",
            "launchctl bootstrap system '\(Self.daemonPlistPath)'",
        ].joined(separator: "\n")

        do {
            _ = try await runAdminScript(shell)
        } catch {
            if let failure = error as? LocalCoreError,
               case .processFailed(_, let stderr) = failure,
               stderr.range(of: "user canceled", options: .caseInsensitive) != nil {
                throw LocalCoreError.installCancelled
            }
            throw error
        }
    }

    private func runAdminScript(_ shell: String) async throws -> String {
        let escaped = shell
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return try await runProcess(
            "/usr/bin/osascript",
            ["-e", "do shell script \"\(escaped)\" with administrator privileges"]
        )
    }

    private func runProcess(_ launchPath: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let stderrData = stderr.fileHandleForReading.readDataToEndOfFile()
                let stdoutData = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let out = String(data: stdoutData, encoding: .utf8) ?? ""
                let err = String(data: stderrData, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: out)
                } else {
                    continuation.resume(
                        throwing: LocalCoreError.processFailed(
                            status: Int(process.terminationStatus),
                            stderr: err.isEmpty ? out : err
                        )
                    )
                }
            }
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let digest = SHA256.hash(data: try Data(contentsOf: url))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func currentTunnelConfig() -> String? {
        guard let data = UserDefaults(suiteName: APP_GROUP_ID)?.data(forKey: "VPNConfig"),
              let options = try? JSONDecoder().decode(EasyTierOptions.self, from: data) else {
            return nil
        }
        return options.config
    }

    // MARK: - Installed payloads

    /// Supervises easytier-core: runs it while `config.toml` exists, restarts
    /// it when the file changes, and stops it when the file disappears.
    private static let watchScript = #"""
    #!/bin/bash
    # EasyTier local core supervisor. Installed by EasyTier.app. Do not edit.
    INSTALL_DIR="/Library/Application Support/EasyTier"
    BIN="${INSTALL_DIR}/easytier-core"
    CONFIG="__CONFIG_FILE__"
    LOG="__LOG_FILE__"
    STATE="__STATE_FILE__"

    write_state() {
      TMP="${STATE}.tmp.$$"
      printf '{"running": %s, "pid": %s, "startedAt": %s, "exitCode": %s, "updatedAt": %s}\n' \
        "$1" "$2" "$3" "$4" "$(date +%s)" > "${TMP}"
      mv -f "${TMP}" "${STATE}"
    }

    write_state false null null null
    while true; do
      if [ -s "${CONFIG}" ]; then
        MTIME=$(stat -f %m "${CONFIG}" 2>/dev/null || echo 0)
        if [ -f "${LOG}" ] && [ "$(stat -f %z "${LOG}" 2>/dev/null || echo 0)" -gt 10485760 ]; then
          : > "${LOG}"
        fi
        chmod 666 "${LOG}" 2>/dev/null
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') starting easytier-core ===" >> "${LOG}"
        STARTED=$(date +%s)
        "${BIN}" --config-file "${CONFIG}" >> "${LOG}" 2>&1 &
        PID=$!
        write_state true "${PID}" "${STARTED}" null
        while kill -0 "${PID}" 2>/dev/null; do
          sleep 2
          CUR=$(stat -f %m "${CONFIG}" 2>/dev/null || echo 0)
          [ "${CUR}" != "${MTIME}" ] && break
        done
        if kill -0 "${PID}" 2>/dev/null; then
          kill "${PID}" 2>/dev/null
          for _ in 1 2 3 4 5; do
            kill -0 "${PID}" 2>/dev/null || break
            sleep 1
          done
          kill -9 "${PID}" 2>/dev/null
          CODE=143
        else
          wait "${PID}" 2>/dev/null
          CODE=$?
        fi
        write_state false null null "${CODE}"
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') easytier-core exited (${CODE}) ===" >> "${LOG}"
        NOW=$(date +%s)
        [ $((NOW - STARTED)) -lt 5 ] && sleep 10
      fi
      sleep 2
    done
    """#

    private static let daemonPlist = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key>
      <string>cn.easytier.core</string>
      <key>ProgramArguments</key>
      <array>
        <string>/bin/bash</string>
        <string>/Library/Application Support/EasyTier/core-watch.sh</string>
      </array>
      <key>RunAtLoad</key>
      <true/>
      <key>KeepAlive</key>
      <true/>
      <key>ProcessType</key>
      <string>Background</string>
    </dict>
    </plist>
    """#
}
#endif
