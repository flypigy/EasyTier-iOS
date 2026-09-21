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
    private static let startTimeoutSeconds = 30.0

    enum LocalCoreError: LocalizedError {
        case coreBinaryMissing
        case optionsMissing
        case configEmpty
        case configWriteFailed(path: String, underlying: String)
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
            case .configWriteFailed(let path, let underlying):
                return "failed to write \(path): \(underlying)"
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
        // The app group container may be unusable for ad-hoc signed apps, so
        // probe it and fall back to Application Support before giving up.
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: APP_GROUP_ID
        )
        let containerUsable = container != nil
            && Self.ensureWritableDir(container!.appendingPathComponent("LocalCore", isDirectory: true))
        if containerUsable, let container {
            stateDir = container.appendingPathComponent("LocalCore", isDirectory: true)
            logURL = container.appendingPathComponent(LOG_FILENAME)
        } else {
            let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("EasyTier", isDirectory: true)
                .appendingPathComponent("LocalCore", isDirectory: true)
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("EasyTierLocalCore", isDirectory: true)
            Self.ensureWritableDir(fallback)
            stateDir = fallback
            logURL = fallback.deletingLastPathComponent().appendingPathComponent(LOG_FILENAME)
        }
    }

    /// Creates the directory and verifies it is actually writable with a probe file.
    @discardableResult
    private static func ensureWritableDir(_ dir: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let probe = dir.appendingPathComponent(".probe-\(UUID().uuidString)")
            try Data("ok".utf8).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            return true
        } catch {
            logger.error(
                "directory \(dir.path, privacy: .public) is not usable: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Connection

    func connect() async throws {
        try await ensureInstalled()
        let config = Self.currentTunnelConfig() ?? ""
        guard !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalCoreError.configEmpty
        }
        Self.logger.info("connect(): writing core config")
        do {
            guard Self.ensureWritableDir(stateDir) else {
                throw LocalCoreError.configWriteFailed(
                    path: stateDir.path,
                    underlying: "cannot create a writable state directory"
                )
            }
            try? FileManager.default.removeItem(at: configURL)
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } catch let error as LocalCoreError {
            throw error
        } catch {
            throw LocalCoreError.configWriteFailed(
                path: configURL.path,
                underlying: error.localizedDescription
            )
        }

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

    private var cliBinaryURL: URL? {
        Bundle.main.url(forResource: "easytier-cli", withExtension: nil)
    }

    private static let fetchLock = NSLock()
    private static var fetchInFlight = false
    private static var lastStatus: (date: Date, status: NetworkStatus)?

    /// Mirrors the `easytier-cli node info` JSON (api_instance.proto NodeInfo).
    private struct CliNodeInfo: Codable {
        struct CliIpList: Codable {
            var publicIPv4: NetworkStatus.IPv4Addr?
            var interfaceIPv4s: [NetworkStatus.IPv4Addr]?
            var publicIPv6: NetworkStatus.IPv6Addr?
            var interfaceIPv6s: [NetworkStatus.IPv6Addr]?

            enum CodingKeys: String, CodingKey {
                case publicIPv4 = "public_ipv4"
                case interfaceIPv4s = "interface_ipv4s"
                case publicIPv6 = "public_ipv6"
                case interfaceIPv6s = "interface_ipv6s"
            }
        }

        var peerId: Int?
        var ipv4Addr: String?
        var hostname: String?
        var version: String?
        var stunInfo: NetworkStatus.STUNInfo?
        var ipList: CliIpList?
        // NodeInfo.listeners is a repeated string in the proto.
        var listeners: [String]?

        enum CodingKeys: String, CodingKey {
            case peerId = "peer_id"
            case ipv4Addr = "ipv4_addr"
            case hostname, version
            case stunInfo = "stun_info"
            case ipList = "ip_list"
            case listeners
        }

        var virtualIPv4: NetworkStatus.IPv4CIDR? {
            LocalCoreController.parseIPv4CIDR(ipv4Addr)
        }
    }

    /// Queries the core's local RPC portal through `easytier-cli` and maps the
    /// result into the same NetworkStatus the NetworkExtension path provides.
    func fetchRunningInfo() async -> NetworkStatus {
        Self.fetchLock.lock()
        if Self.fetchInFlight, let cached = Self.lastStatus?.status {
            Self.fetchLock.unlock()
            return cached
        }
        if let last = Self.lastStatus, Date().timeIntervalSince(last.date) < 1.0 {
            Self.fetchLock.unlock()
            return last.status
        }
        Self.fetchInFlight = true
        Self.fetchLock.unlock()
        defer {
            Self.fetchLock.lock()
            Self.fetchInFlight = false
            Self.fetchLock.unlock()
        }

        let running = isCoreRunning()
        guard running, let cli = cliBinaryURL else {
            return Self.cacheAndReturn(Self.assemble(node: nil, pairs: [], running: false))
        }

        async let pairsOutput = runProcess(cli.path, ["--verbose", "peer"])
        async let nodeOutput = runProcess(cli.path, ["--verbose", "node", "info"])
        let pairsJSON = try? await pairsOutput
        let nodeJSON = try? await nodeOutput

        var pairs: [NetworkStatus.PeerRoutePair] = []
        if let pairsJSON, let data = pairsJSON.data(using: .utf8) {
            pairs = (try? JSONDecoder().decode([NetworkStatus.PeerRoutePair].self, from: data)) ?? []
        }
        var node: CliNodeInfo?
        if let nodeJSON, let data = nodeJSON.data(using: .utf8) {
            node = try? JSONDecoder().decode(CliNodeInfo.self, from: data)
        }
        return Self.cacheAndReturn(Self.assemble(node: node, pairs: pairs, running: running))
    }

    private static func cacheAndReturn(_ status: NetworkStatus) -> NetworkStatus {
        lastStatus = (Date(), status)
        return status
    }

    private static func parseIPv4CIDR(_ string: String?) -> NetworkStatus.IPv4CIDR? {
        guard let string, !string.isEmpty else { return nil }
        let parts = string.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = NetworkStatus.IPv4Addr(String(parts[0])) else { return nil }
        let prefix = parts.count > 1 ? Int(parts[1]) ?? 32 : 32
        return NetworkStatus.IPv4CIDR(address: address, networkLength: prefix)
    }

    private static func assemble(
        node: CliNodeInfo?,
        pairs: [NetworkStatus.PeerRoutePair],
        running: Bool
    ) -> NetworkStatus {
        var myNodeInfo: NetworkStatus.MyNodeInfo?
        if let node {
            // With DHCP the config IPv4 can be empty; the route table then
            // holds the actually assigned address.
            var virtualIPv4 = node.virtualIPv4
            if virtualIPv4 == nil, let peerId = node.peerId,
               let localRoute = pairs.first(where: { $0.route.peerId == peerId }) {
                virtualIPv4 = localRoute.route.ipv4Addr
            }
            let ips = node.ipList.map {
                NetworkStatus.MyNodeInfo.IPList(
                    publicIPv4: $0.publicIPv4,
                    interfaceIPv4s: $0.interfaceIPv4s,
                    publicIPv6: $0.publicIPv6,
                    interfaceIPv6s: $0.interfaceIPv6s
                )
            }
            myNodeInfo = NetworkStatus.MyNodeInfo(
                virtualIPv4: virtualIPv4,
                hostname: node.hostname ?? "",
                version: node.version ?? "",
                ips: ips,
                stunInfo: node.stunInfo,
                listeners: node.listeners?.map { NetworkStatus.Url(url: $0) },
                vpnPortalCfg: nil,
                peerID: node.peerId
            )
        }
        return NetworkStatus(
            devName: "utun",
            myNodeInfo: myNodeInfo,
            events: [],
            routes: pairs.map(\.route),
            peers: pairs.compactMap(\.peer),
            peerRoutePairs: pairs,
            running: running,
            errorMsg: nil
        )
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

    // MARK: - Applied network settings

    /// Approximates the applied tunnel settings the NetworkExtension path
    /// reports by reading the live utun interface, the routing table and the
    /// saved options.
    func fetchNetworkSettings() async -> TunnelNetworkSettingsSnapshot? {
        guard isCoreRunning() else { return nil }
        let info = await fetchRunningInfo()
        guard let virtualIPv4 = info.myNodeInfo?.virtualIPv4 else { return nil }
        let address = virtualIPv4.address.description

        guard let output = try? await runProcess("/sbin/ifconfig", []) else { return nil }
        guard let (interface, mtu) = Self.findTunnelInterface(in: output, address: address) else {
            return nil
        }

        var includedRoutes: [TunnelNetworkSettingsSnapshot.IPv4Subnet] = []
        if let routesOutput = try? await runProcess("/usr/sbin/netstat", ["-rn", "-f", "inet"]) {
            includedRoutes = Self.routes(in: routesOutput, interface: interface)
        }

        var dns: TunnelNetworkSettingsSnapshot.DNS?
        if let data = UserDefaults(suiteName: APP_GROUP_ID)?.data(forKey: "VPNConfig"),
           let options = try? JSONDecoder().decode(EasyTierOptions.self, from: data),
           !options.dns.isEmpty {
            dns = TunnelNetworkSettingsSnapshot.DNS(servers: options.dns)
        }

        let mask = Self.subnetMask(prefix: virtualIPv4.networkLength)
        return TunnelNetworkSettingsSnapshot(
            ipv4: .init(
                addresses: [address],
                subnetMasks: [mask],
                includedRoutes: includedRoutes.isEmpty ? nil : includedRoutes
            ),
            dns: dns,
            mtu: mtu
        )
    }

    static func findTunnelInterface(
        in output: String,
        address: String
    ) -> (name: String, mtu: UInt32?)? {
        var name: String?
        var mtu: UInt32?
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if !rawLine.hasPrefix(" ") && !rawLine.hasPrefix("\t") {
                // Interface header, e.g. "utun5: flags=... mtu 1380"
                let tokens = line.split(separator: " ").map(String.init)
                guard let nameToken = tokens.first, nameToken.hasSuffix(":") else {
                    name = nil
                    mtu = nil
                    continue
                }
                name = String(nameToken.dropLast())
                mtu = tokens.firstIndex(of: "mtu").flatMap {
                    $0 + 1 < tokens.count ? UInt32(tokens[$0 + 1]) : nil
                }
            } else if let name, line.hasPrefix("inet \(address) ") || line == "inet \(address)" {
                return (name, mtu)
            }
        }
        return nil
    }

    static func routes(
        in output: String,
        interface: String
    ) -> [TunnelNetworkSettingsSnapshot.IPv4Subnet] {
        var result = Set<TunnelNetworkSettingsSnapshot.IPv4Subnet>()
        for rawLine in output.split(separator: "\n") {
            let columns = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
            guard columns.count >= 4, columns[3] == interface,
                  let subnet = Self.routeDestinationSubnet(columns[0]) else {
                continue
            }
            result.insert(subnet)
        }
        return Array(result).sorted { $0.address < $1.address }
    }

    /// Parses netstat destinations like "default", "10.144.144.10" and the
    /// macOS-shortened "10.144.144/24" (or "192.168.31", which implies the
    /// natural classful mask) into address + subnet mask pairs.
    static func routeDestinationSubnet(_ destination: String) -> TunnelNetworkSettingsSnapshot.IPv4Subnet? {
        if destination == "default" {
            return TunnelNetworkSettingsSnapshot.IPv4Subnet(
                address: "0.0.0.0",
                subnetMask: Self.subnetMask(prefix: 0)
            )
        }
        let parts = destination.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var octets = parts[0].split(separator: ".").compactMap { UInt8($0) }
        guard !octets.isEmpty, octets.count <= 4,
              octets.count == parts[0].split(separator: ".").count else {
            return nil
        }
        let prefix: Int
        if parts.count > 1 {
            guard let explicit = Int(parts[1]), explicit >= 0, explicit <= 32 else { return nil }
            prefix = explicit
        } else {
            // netstat drops trailing ".0" and the mask for natural networks:
            // "10" = /8, "10.144" = /16, "10.144.144" = /24, a full address = /32.
            prefix = octets.count * 8 >= 32 ? 32 : octets.count * 8
        }
        while octets.count < 4 {
            octets.append(0)
        }
        let address = octets.map(String.init).joined(separator: ".")
        return TunnelNetworkSettingsSnapshot.IPv4Subnet(
            address: address,
            subnetMask: Self.subnetMask(prefix: prefix)
        )
    }

    static func subnetMask(prefix: Int) -> String {
        let value: UInt32 = prefix <= 0 ? 0 : prefix >= 32 ? .max : ~UInt32(0) << (32 - prefix)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return bytes.map(String.init).joined(separator: ".")
    }

    // MARK: - Selected profile hint

    /// Suite defaults ("group.*") may not persist reliably for ad-hoc signed
    /// apps, so the last selected profile name is mirrored to a plain file and
    /// restored from it when AppStorage comes back empty.
    private var selectedProfileHintURL: URL {
        stateDir.appendingPathComponent("selected-profile")
    }

    func storeSelectedProfileHint(_ name: String?) {
        if let name {
            try? name.write(to: selectedProfileHintURL, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: selectedProfileHintURL)
        }
    }

    func loadSelectedProfileHint() -> String? {
        guard let raw = try? String(contentsOf: selectedProfileHintURL, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
            let scriptMatches = (try? String(
                contentsOf: URL(fileURLWithPath: "\(Self.installDir)/\(Self.watchScriptName)"),
                encoding: .utf8
            )) == Self.renderedWatchScript()
            if sameBinary && scriptMatches {
                return
            }
            Self.logger.info("installed service is outdated (binary or paths changed), reinstalling")
        }
        try await installService(bundledBinary: bundled)
    }

    private func installService(bundledBinary: URL) async throws {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("EasyTierInstall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let scriptURL = staging.appendingPathComponent(Self.watchScriptName)
        try Self.renderedWatchScript().write(to: scriptURL, atomically: true, encoding: .utf8)
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

    private static func renderedWatchScript() -> String {
        watchScript
            .replacingOccurrences(of: "__CONFIG_FILE__", with: Self.shared.configURL.path)
            .replacingOccurrences(of: "__LOG_FILE__", with: Self.shared.logURL.path)
            .replacingOccurrences(of: "__STATE_FILE__", with: Self.shared.stateURL.path)
    }

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
        mkdir -p "$(dirname "${LOG}")" "$(dirname "${STATE}")" 2>/dev/null
        MTIME=$(stat -f %m "${CONFIG}" 2>/dev/null || echo 0)
        if [ -f "${LOG}" ] && [ "$(stat -f %z "${LOG}" 2>/dev/null || echo 0)" -gt 10485760 ]; then
          : > "${LOG}"
        fi
        chmod 666 "${LOG}" 2>/dev/null
        echo "=== $(date '+%Y-%m-%d %H:%M:%S') starting easytier-core ===" >> "${LOG}"
        STARTED=$(date +%s)
        "${BIN}" --rpc-portal "127.0.0.1:15888" --config-file "${CONFIG}" >> "${LOG}" 2>&1 &
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
