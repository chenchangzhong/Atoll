/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import Network
import Defaults
import UniformTypeIdentifiers
import Darwin
import CryptoKit
import Security

struct LocalSendDeviceInfo: Identifiable, Hashable, Sendable {
    let id: String
    let alias: String
    let ip: String
    let port: Int
    let https: Bool
    let model: String?

    var displayName: String {
        if let model, !model.isEmpty {
            return "\(alias) (\(model))"
        }
        return alias
    }

    var baseURL: String {
        let scheme = https ? "https" : "http"
        return "\(scheme)://\(ip):\(port)"
    }
}

enum LocalSendTransferState: Equatable {
    case idle
    case sending
    case completed
    case failed(String)
    case rejected(deviceID: String)
}

@MainActor
final class LocalSendService: NSObject, ObservableObject {
    static let shared = LocalSendService()

    @Published private(set) var devices: [LocalSendDeviceInfo] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSending = false
    @Published private(set) var sendProgress: Double = 0
    @Published private(set) var transferState: LocalSendTransferState = .idle
    @Published private(set) var rejectedDeviceIDs: Set<String> = []
    @Published var selectedDeviceID: String {
        didSet { Defaults[.localSendSelectedDeviceID] = selectedDeviceID }
    }

    private let multicastGroupHost = "224.0.0.167"
    private let defaultPort = 53317
    // BSD-socket multicast (same approach as upstream LocalSend's
    // RawDatagramSocket). NWConnectionGroup cannot join on non-default
    // interfaces (its shared inbox + NECP reject the join), so the raw socket
    // is the only reliable multi-homed path.
    nonisolated(unsafe) private var multicastRecvSocket: Int32 = -1
    nonisolated(unsafe) private var multicastSendSockets: [String: Int32] = [:]  // local IP -> fd
    /// The interface addresses the sockets above were built for, so a scan can
    /// notice that the network changed underneath them (DHCP renewal, sleep/wake,
    /// cable plugged in later).
    nonisolated(unsafe) private var multicastInterfaceIPs: [String] = []
    /// Bumped when the sockets are (re)created, when they are torn down, and when
    /// a receive loop starts. Each loop only serves the generation it captured,
    /// so a closed or recycled descriptor can never keep a stale loop alive.
    nonisolated(unsafe) private var multicastGeneration: UInt64 = 0
    nonisolated(unsafe) private var receiveLoopTask: Task<Void, Never>?
    private var registerListener: NWListener?
    private var cleanupTask: Task<Void, Never>?
    private var announceTask: Task<Void, Never>?
    private var activeRefreshTask: Task<Void, Never>?
    private var refreshSessionID = UUID()
    private var discoveredByID: [String: (device: LocalSendDeviceInfo, lastSeen: Date)] = [:]
    private var recentProbeIPs: [String] = []
    private var knownPeerIPs: [String] = []
    private var isStarted = false
    private var completionDismissTask: Task<Void, Never>?
    private var idleStopTask: Task<Void, Never>?
    private let idleStopIntervalNanos: UInt64 = 60_000_000_000

    private override init() {
        selectedDeviceID = Defaults[.localSendSelectedDeviceID]
        super.init()
    }
    
    func clearRejectedStatus(for deviceID: String) {
        rejectedDeviceIDs.remove(deviceID)
    }
    
    func clearAllRejectedStatuses() {
        rejectedDeviceIDs.removeAll()
    }

    func startDiscovery() {
        cancelIdleStop()
        guard !isStarted else { return }
        isStarted = true
        // Arm the idle watchdog; it re-arms itself while discovery is still
        // wanted, so an unused session tears down after the idle interval.
        scheduleIdleStopIfIdle()

        startRegisterListenerIfNeeded()

        startMulticastSockets()
        startReceiveLoop()

        sendAnnouncement()

        cleanupTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                self.cleanupStale()
            }
        }

        announceTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self.sendAnnouncement()
            }
        }
    }

    /// One shared receive socket (bound 0.0.0.0:port, joined on every interface)
    /// + one send socket per interface (IP_MULTICAST_IF scoped). The two halves
    /// are independent on purpose: announcing has to keep working even when
    /// 53317 cannot be bound.
    nonisolated private func startMulticastSockets() {
        stopMulticastSockets()
        multicastGeneration &+= 1

        // Enumerate once so the join loop and the egress loop cannot disagree.
        let interfaces = Self.discoverableIPv4Interfaces()

        startReceiveSocket(interfaces: interfaces)

        for interface in interfaces {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { continue }
            // IP_MULTICAST_IF takes a bare in_addr on Darwin (IP_ADD_MEMBERSHIP
            // is the one that takes ip_mreq). Passing ip_mreq here failed with
            // EADDRNOTAVAIL and left the socket on the routing table's default
            // egress: with Ethernet plugged in the announcements left via the
            // cable instead of Wi-Fi, so phones on Wi-Fi were never discovered.
            var egress = ipv4Address(interface.ip)
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &egress, socklen_t(MemoryLayout<in_addr>.size)) == 0 else {
                Logger.log("LocalSend multicast egress on \(interface.ip) failed (errno \(errno))", category: .extensions)
                close(fd)
                continue
            }
            // Loop our own announces back? No — we filter our fingerprint anyway.
            var loop: UInt8 = 0
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_LOOP, &loop, 1)
            multicastSendSockets[interface.ip] = fd
        }
        multicastInterfaceIPs = interfaces.map(\.ip)
    }

    /// Binds the shared receive socket and joins the multicast group on every
    /// interface.
    ///
    /// `SO_REUSEPORT` is required rather than optional: the official LocalSend
    /// app binds 53317 with it too, and with `SO_REUSEADDR` alone the bind fails
    /// with EADDRINUSE whenever another LocalSend instance is already running
    /// (and vice versa: we would hold the port exclusively and break theirs).
    /// Trade-off: with REUSEPORT the kernel may hand a *unicast* reply to another
    /// process sharing the port, while multicast is still delivered to all.
    nonisolated private func startReceiveSocket(interfaces: [(ip: String, name: String)]) {
        let recv = socket(AF_INET, SOCK_DGRAM, 0)
        guard recv >= 0 else {
            Logger.log("LocalSend multicast receive socket creation failed (errno \(errno))", category: .extensions)
            return
        }

        var reuse: Int32 = 1
        setsockopt(recv, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(recv, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(defaultPort).bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult: Int32 = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(recv, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Logger.log("LocalSend multicast bind failed (errno \(errno), \(String(cString: strerror(errno)))); continuing with announcements only", category: .extensions)
            close(recv)
            return
        }

        var joined = 0
        for interface in interfaces {
            var mreq = ip_mreq()
            mreq.imr_multiaddr = ipv4Address(multicastGroupHost)
            mreq.imr_interface = ipv4Address(interface.ip)
            if setsockopt(recv, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 {
                joined += 1
            } else {
                Logger.log("LocalSend multicast join on \(interface.ip) failed (errno \(errno))", category: .extensions)
            }
        }

        // Non-blocking so recvfrom cannot block on its own; the receive loop is
        // torn down by the 200 ms poll timeout plus the generation check (closing
        // the fd does not wake a blocked poll on macOS).
        let flags = fcntl(recv, F_GETFL, 0)
        _ = fcntl(recv, F_SETFL, flags | O_NONBLOCK)
        multicastRecvSocket = recv
        Logger.log("LocalSend multicast joined on \(joined) interface(s)", category: .extensions)
    }

    nonisolated private func stopMulticastSockets() {
        // Any teardown invalidates a running receive loop, so bump here as well
        // as on start: the loop's poll() is not woken by close() and would
        // otherwise keep polling a closed (possibly recycled) descriptor.
        multicastGeneration &+= 1
        if multicastRecvSocket >= 0 {
            close(multicastRecvSocket)
            multicastRecvSocket = -1
        }
        for fd in multicastSendSockets.values where fd >= 0 {
            close(fd)
        }
        multicastSendSockets.removeAll()
        multicastInterfaceIPs = []
    }

    /// Waits for datagrams on the receive socket (blocking on poll with a 200 ms
    /// timeout, so an idle socket costs no repeated syscalls).
    nonisolated private func startReceiveLoop() {
        guard multicastRecvSocket >= 0 else { return }
        let fd = multicastRecvSocket
        let port = defaultPort
        // Each loop owns a fresh generation, so two loops can never poll the same
        // socket even if a future call site forgets to rebuild first.
        multicastGeneration &+= 1
        let generation = multicastGeneration
        receiveLoopTask?.cancel()
        receiveLoopTask = Task.detached(priority: .utility) { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65_536)
            var source = sockaddr_in()
            while !Task.isCancelled, self?.multicastGeneration == generation, self?.multicastRecvSocket == fd {
                // Block in poll() with a timeout instead of re-calling recvfrom
                // every 20 ms: one syscall per wakeup. Note that closing the
                // socket does NOT wake poll() on macOS, so teardown latency is
                // bounded by this timeout; the generation check above keeps a
                // stale loop off a recycled descriptor.
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 200)
                if ready < 0 {
                    if errno == EINTR { continue }
                    break
                }
                if descriptor.revents & Int16(POLLNVAL) != 0 { break }
                guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else {
                    // Error/hangup with no data would keep poll returning at once;
                    // treat it as the end of this socket instead of spinning.
                    if descriptor.revents & (Int16(POLLERR) | Int16(POLLHUP)) != 0 { break }
                    continue
                }
                // Re-check after waking: the loop may have been superseded while
                // poll was blocked (closing the fd does not wake it).
                guard !Task.isCancelled,
                      self?.multicastGeneration == generation,
                      self?.multicastRecvSocket == fd
                else { break }

                var sourceLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                // Must be the Array method, not the global
                // `withUnsafeMutableBytes(of: &buffer)`: the global form exposes
                // only the 8-byte Array header, so recvfrom would write the whole
                // datagram over this task's stack frame (that crashed the app on
                // 2026-09-18: SIGSEGV in swift_retain from this closure).
                let count = buffer.withUnsafeMutableBytes { raw -> Int in
                    withUnsafeMutablePointer(to: &source) { srcPtr in
                        srcPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            recvfrom(fd, raw.baseAddress, raw.count, 0, sockPtr, &sourceLen)
                        }
                    }
                }
                guard count > 0 else { continue }
                let data = Data(buffer.prefix(count))
                let senderIP = Self.ipv4String(from: source)
                let endpoint = NWEndpoint.hostPort(
                    host: .init(senderIP),
                    port: .init(integerLiteral: NWEndpoint.Port.IntegerLiteralType(port))
                )
                await Task { @MainActor [weak self] in
                    self?.handleIncoming(content: data, endpoint: endpoint)
                }.value
            }
        }
    }

    nonisolated private static func ipv4String(from addr: sockaddr_in) -> String {
        var copy = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var sa = copy.sin_addr
        inet_ntop(AF_INET, &sa, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    nonisolated private func ipv4Address(_ s: String) -> in_addr {
        var value = in_addr()
        inet_pton(AF_INET, s, &value.s_addr)
        return value
    }

    func refreshDeviceScan() {
        activeRefreshTask?.cancel()
        startDiscovery()

        // startDiscovery() early-returns while discovery is running, so the
        // sockets would otherwise keep bindings for interfaces that no longer
        // exist (DHCP renewal, sleep/wake, cable plugged in after the picker
        // opened). Rebuild them when the interface set changed, or when the
        // receive socket never came up (bind failed earlier).
        let interfaceIPs = Self.discoverableIPv4Interfaces().map(\.ip)
        if interfaceIPs != multicastInterfaceIPs || (!interfaceIPs.isEmpty && multicastRecvSocket < 0) {
            Logger.log("LocalSend rebuilding multicast sockets for \(interfaceIPs.count) interface(s)", category: .extensions)
            startMulticastSockets()
            startReceiveLoop()
            sendAnnouncement()
        }

        // The register listener can fail on the first attempt (port already taken,
        // network not ready) and had no second chance; a scan is a cheap retry.
        startRegisterListenerIfNeeded()

        let sessionID = UUID()
        refreshSessionID = sessionID
        isRefreshing = true

        // Keep listener state and run a LocalSend-like refresh sequence:
        // multicast announce burst first, then targeted/fallback HTTP discovery.
        activeRefreshTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }

            let startedAt = Date()
            defer {
                if self.refreshSessionID == sessionID {
                    self.isRefreshing = false
                    self.activeRefreshTask = nil
                    self.scheduleIdleStopIfIdle()
                }
            }

            let burstDelays: [UInt64] = [100_000_000, 500_000_000, 2_000_000_000]
            for delay in burstDelays {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                self.sendAnnouncement()
            }

            guard !Task.isCancelled else { return }
            await self.probeNearbyDevicesDirectly(limit: 20, timeout: 0.14)

            guard !Task.isCancelled else { return }
            if !self.hasFreshDiscovery(since: startedAt) {
                await self.probeLocalSubnets(timeout: 0.12)
            }

            guard !Task.isCancelled else { return }
            self.pruneUnavailableDevices(since: startedAt)
        }
    }

    /// Tears down discovery (multicast sockets, TCP listener, periodic loops).
    /// Safe to call when not started. Next startDiscovery() re-creates everything.
    func stopDiscovery() {
        cancelIdleStop()
        guard isStarted else { return }
        isStarted = false

        cleanupTask?.cancel()
        cleanupTask = nil
        announceTask?.cancel()
        announceTask = nil
        activeRefreshTask?.cancel()
        activeRefreshTask = nil

        receiveLoopTask?.cancel()
        receiveLoopTask = nil
        stopMulticastSockets()
        registerListener?.cancel()
        registerListener = nil

        isRefreshing = false
        // Keep discoveredByID / knownPeerIPs / recentProbeIPs so the next picker
        // open can show the last known devices until the first scan of that
        // session prunes entries older than its start.
    }

    /// Keeps an idle watchdog armed. It fires after the idle interval and stops
    /// discovery only when nothing is in flight and no devices are known;
    /// otherwise it re-arms itself. Cancelling here is deliberate: an armed timer
    /// must not fire while discovery is still wanted, but simply returning would
    /// leave *nothing* armed and discovery would then run until the app quits.
    /// (The picker stops discovery directly when it hides.)
    private func scheduleIdleStopIfIdle() {
        cancelIdleStop()
        guard isStarted else { return }
        idleStopTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.idleStopIntervalNanos ?? 60_000_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.isSending, !self.isRefreshing, self.devices.isEmpty else {
                self.scheduleIdleStopIfIdle()
                return
            }
            self.stopDiscovery()
            Logger.log("LocalSend discovery stopped after idle", category: .extensions)
        }
    }

    private func cancelIdleStop() {
        idleStopTask?.cancel()
        idleStopTask = nil
    }

    private func pruneUnavailableDevices(since date: Date) {
        let previousCount = discoveredByID.count
        discoveredByID = discoveredByID.filter { $0.value.lastSeen >= date }
        if discoveredByID.count != previousCount {
            refreshDevices()
        }
    }

    private func probeNearbyDevicesDirectly(limit: Int = 12, timeout: TimeInterval = 0.14) async {
        let port = defaultPort
        let candidates = candidateIPsForActiveProbe(limit: max(1, limit))
        guard !candidates.isEmpty else { return }
        let deadline = Date().addingTimeInterval(1.0)

        await withTaskGroup(of: LocalSendDeviceInfo?.self) { group in
            let maxConcurrent = 4
            var iterator = candidates.makeIterator()

            for _ in 0 ..< min(maxConcurrent, candidates.count) {
                guard let ip = iterator.next() else { break }
                group.addTask {
                    await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                }
            }

            while let result = await group.next() {
                if Date() > deadline {
                    group.cancelAll()
                    return
                }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                if let device = result {
                    discoveredByID[device.id] = (device, Date())
                    rememberKnownPeerIP(device.ip)
                    rememberRecentProbeIP(device.ip)
                }

                if let ip = iterator.next() {
                    group.addTask {
                        await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                    }
                }
            }
        }

        refreshDevices()
    }

    private func candidateIPsForActiveProbe(limit: Int) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        if let selected = devices.first(where: { $0.id == selectedDeviceID })?.ip,
           seen.insert(selected).inserted {
            ordered.append(selected)
        }

        for ip in recentProbeIPs where seen.insert(ip).inserted {
            ordered.append(ip)
        }

        for ip in discoveredByID.values.map(\.device.ip) where seen.insert(ip).inserted {
            ordered.append(ip)
        }

        for ip in knownPeerIPs where seen.insert(ip).inserted {
            ordered.append(ip)
        }

        if ordered.count > limit {
            return Array(ordered.prefix(limit))
        }
        return ordered
    }

    /// Sweeps every locally attached IPv4 /24 (skipping the local host on each).
    private func probeLocalSubnets(timeout: TimeInterval) async {
        let interfaces = Self.discoverableIPv4Interfaces()
        guard !interfaces.isEmpty else { return }

        var candidates: [String] = []
        for interface in interfaces {
            let parts = interface.ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            let prefix = parts.prefix(3).joined(separator: ".")
            let host = Int(parts[3]) ?? 0
            candidates.append(contentsOf: (1 ... 254)
                .filter { $0 != host }
                .map { "\(prefix).\($0)" })
        }

        // Bound the sweep: several interfaces is ~760 probes, and every refresh
        // would otherwise rescan every subnet with no upper limit.
        await probeExactIPs(candidates, timeout: timeout, concurrency: 50, deadline: Date().addingTimeInterval(2.5))
    }

    private func probeExactIPs(
        _ ips: [String],
        timeout: TimeInterval,
        concurrency: Int,
        deadline: Date? = nil
    ) async {
        let port = defaultPort
        let unique = Array(NSOrderedSet(array: ips).compactMap { $0 as? String })
        guard !unique.isEmpty else { return }

        await withTaskGroup(of: LocalSendDeviceInfo?.self) { group in
            var iterator = unique.makeIterator()

            for _ in 0 ..< min(max(1, concurrency), unique.count) {
                guard let ip = iterator.next() else { break }
                group.addTask {
                    await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                }
            }

            while let result = await group.next() {
                if let deadline, Date() > deadline {
                    group.cancelAll()
                    return
                }

                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }

                if let device = result {
                    discoveredByID[device.id] = (device, Date())
                    rememberKnownPeerIP(device.ip)
                    rememberRecentProbeIP(device.ip)
                }

                if let ip = iterator.next() {
                    group.addTask {
                        await Self.probeDeviceInfo(at: ip, port: port, timeout: timeout)
                    }
                }
            }
        }

        refreshDevices()
    }

    private func hasFreshDiscovery(since date: Date) -> Bool {
        discoveredByID.values.contains { $0.lastSeen >= date }
    }

    private nonisolated static func probeDeviceInfo(at ip: String, port: Int, timeout: TimeInterval) async -> LocalSendDeviceInfo? {
        let schemes = ["http", "https"]
        let paths = ["/api/localsend/v2/info"]

        for scheme in schemes {
            for path in paths {
                guard var components = URLComponents(string: "\(scheme)://\(ip):\(port)\(path)") else { continue }
                components.queryItems = [
                    URLQueryItem(name: "fingerprint", value: "atoll.localsend.bridge"),
                ]
                guard let url = components.url else { continue }

                var request = URLRequest(url: url)
                request.timeoutInterval = timeout
                request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

                do {
                    let (data, response) = try await probeSession.data(for: request)
                    guard let http = response as? HTTPURLResponse,
                          (200 ... 299).contains(http.statusCode),
                          let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let fingerprint = json["fingerprint"] as? String,
                          let alias = json["alias"] as? String,
                          fingerprint != "atoll.localsend.bridge"
                    else {
                        continue
                    }

                    let model = json["deviceModel"] as? String
                    let usesHTTPS = (json["protocol"] as? String) == "https" || scheme == "https"

                    return LocalSendDeviceInfo(
                        id: fingerprint,
                        alias: alias,
                        ip: ip,
                        port: port,
                        https: usesHTTPS,
                        model: model
                    )
                } catch {
                    continue
                }
            }
        }

        return nil
    }

    private nonisolated static let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Per-request timeouts (0.12–0.35 s) are what callers set; the resource
        // timeout only has to stay above them instead of silently capping them.
        config.timeoutIntervalForRequest = 0.2
        config.timeoutIntervalForResource = 1.0
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: LocalSendTLSDelegate(), delegateQueue: nil)
    }()

    private func rememberRecentProbeIP(_ ip: String) {
        guard isValidIPv4(ip) else { return }
        recentProbeIPs.removeAll { $0 == ip }
        recentProbeIPs.insert(ip, at: 0)
        if recentProbeIPs.count > 12 {
            recentProbeIPs = Array(recentProbeIPs.prefix(12))
        }
    }

    private func rememberKnownPeerIP(_ ip: String) {
        guard isValidIPv4(ip) else { return }
        knownPeerIPs.removeAll { $0 == ip }
        knownPeerIPs.insert(ip, at: 0)
        if knownPeerIPs.count > 48 {
            knownPeerIPs = Array(knownPeerIPs.prefix(48))
        }
    }

    /// Interface names that never carry useful LAN discovery traffic. Bridged
    /// interfaces are deliberately absent: macOS Internet Sharing puts the LAN
    /// side on `bridge100`/`ap1`, which is exactly where hotspot clients live.
    private static let excludedInterfacePrefixes = ["utun", "awdl", "llw", "lo", "vmnet"]

    /// All usable local IPv4s (UP, non-loopback, non-link-local) with their
    /// interface names, excluding tunnels and Apple internal interfaces.
    nonisolated static func discoverableIPv4Interfaces() -> [(ip: String, name: String)] {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }

        var seen = Set<String>()
        var result: [(ip: String, name: String)] = []

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }

            let family = current.pointee.ifa_addr.pointee.sa_family
            let flags = Int32(current.pointee.ifa_flags)
            guard family == UInt8(AF_INET),
                  (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0
            else { continue }

            let name = String(cString: current.pointee.ifa_name)
            if excludedInterfacePrefixes.contains(where: { name.hasPrefix($0) }) { continue }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            var addr = current.pointee.ifa_addr.pointee
            let result2 = getnameinfo(
                &addr,
                socklen_t(current.pointee.ifa_addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result2 == 0 else { continue }

            let ip = String(cString: hostBuffer)
            guard isValidIPv4Static(ip), !ip.hasPrefix("169.254.") else { continue }
            if seen.insert(ip).inserted {
                result.append((ip, name))
            }
        }

        return result
    }

    private nonisolated static func isValidIPv4Static(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let v = Int(p), (0 ... 255).contains(v) else { return false }
        }
        return true
    }

    private func isValidIPv4(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }
        for p in parts {
            guard let v = Int(p), (0 ... 255).contains(v) else { return false }
        }
        return true
    }

    func send(items: [Any]) async throws {
        let startedAt = Date()
        cancelIdleStop()
        isSending = true
        sendProgress = 0
        transferState = .sending
        completionDismissTask?.cancel()

        let selectedTarget = devices.first(where: { $0.id == selectedDeviceID }) ?? devices.first

        do {
            guard let target = selectedTarget else {
                throw LocalSendServiceError.noDeviceSelected
            }

            let files = try await buildTransferFiles(from: items)
            guard !files.isEmpty else { throw LocalSendServiceError.noTransferableItems }

            let prepare = try await prepareUpload(files: files, to: target)
            guard !prepare.fileTokens.isEmpty else {
                sendProgress = 1
                await finishSending(startedAt: startedAt, success: true)
                return
            }

            let uploads: [(TransferFile, String)] = files.compactMap { file in
                guard let token = prepare.fileTokens[file.id] else { return nil }
                return (file, token)
            }

            // Compute total bytes to provide smooth overall progress
            let totalBytes = uploads.reduce(Int64(0)) { acc, entry in acc + Int64(entry.0.data.count) }
            var bytesCompleted: Int64 = 0

            for (index, entry) in uploads.enumerated() {
                let file = entry.0
                let fileSize = Int64(file.data.count)

                try await upload(file: file, sessionID: prepare.sessionID, token: entry.1, to: target) { fileFraction in
                    if totalBytes > 0 {
                        let currentSent = Int64(Double(fileSize) * fileFraction)
                        let overall = Double(bytesCompleted + currentSent) / Double(totalBytes)
                        Task { @MainActor in self.sendProgress = overall }
                    } else {
                        // Fallback to file-index-based progress when sizes unknown
                        Task { @MainActor in self.sendProgress = Double(index) / Double(max(uploads.count, 1)) }
                    }
                }

                bytesCompleted += fileSize
            }

            sendProgress = 1
            await finishSending(startedAt: startedAt, success: true)
        } catch let error as LocalSendServiceError {
            if case .transferRejected = error {
                // Key the marker off the device actually sent to, not off the
                // persisted selection (send falls back to devices.first).
                let rejectedID = selectedTarget?.id ?? selectedDeviceID
                rejectedDeviceIDs.insert(rejectedID)
                transferState = .rejected(deviceID: rejectedID)
            } else {
                transferState = .failed(error.localizedDescription)
            }
            await finishSending(startedAt: startedAt, success: false)
            throw error
        } catch {
            // Callers alert on the thrown error, so hand them the mapped text
            // rather than the raw "network connection was interrupted".
            let mapped = transferFailureMessage(for: error, target: selectedTarget)
            transferState = .failed(mapped ?? error.localizedDescription)
            await finishSending(startedAt: startedAt, success: false)
            if let mapped {
                throw LocalSendTransferFailure(message: mapped)
            }
            throw error
        }
    }

    private func finishSending(startedAt: Date, success: Bool) async {
        let elapsed = Date().timeIntervalSince(startedAt)
        let minimumVisibleDuration: TimeInterval = 0.8
        if elapsed < minimumVisibleDuration {
            let remaining = minimumVisibleDuration - elapsed
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        isSending = false
        sendProgress = 0
        
        if success {
            transferState = .completed
            // Auto-dismiss completed state after 3 seconds
            completionDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if case .completed = self.transferState {
                    self.transferState = .idle
                }
            }
        } else {
            // Auto-dismiss failed/rejected state after 4 seconds
            completionDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if case .failed = self.transferState {
                    self.transferState = .idle
                } else if case .rejected = self.transferState {
                    self.transferState = .idle
                }
            }
        }
        scheduleIdleStopIfIdle()
    }

    private func sendAnnouncement() {
        let payload: [String: Any] = [
            "alias": Host.current().localizedName ?? "Atoll",
            "version": "2.1",
            "deviceModel": "Mac",
            "deviceType": "desktop",
            "fingerprint": "atoll.localsend.bridge",
            "port": defaultPort,
            // Use HTTP here so LocalSend peers can quickly fail over to UDP response
            // when Atoll is not serving LocalSend register endpoint.
            "protocol": "http",
            "download": false,
            "announcement": true,
            "announce": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        var dest = sockaddr_in()
        dest.sin_family = sa_family_t(AF_INET)
        dest.sin_port = in_port_t(defaultPort).bigEndian
        dest.sin_addr = ipv4Address(multicastGroupHost)
        var failures = 0
        var sockets = 0
        withUnsafePointer(to: &dest) { destPtr in
            destPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                data.withUnsafeBytes { raw in
                    for fd in multicastSendSockets.values where fd >= 0 {
                        sockets += 1
                        if sendto(fd, raw.baseAddress, raw.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size)) < 0 {
                            failures += 1
                        }
                    }
                }
            }
        }
        // A stale IP_MULTICAST_IF (interface changed underneath us) shows up here
        // and nowhere else, so surface it instead of swallowing it.
        if sockets == 0 {
            Logger.log("LocalSend announcement skipped: no multicast send socket", category: .extensions)
        } else if failures == sockets {
            Logger.log("LocalSend announcement failed on all \(sockets) socket(s) (errno \(errno))", category: .extensions)
        } else if failures > 0 {
            Logger.log("LocalSend announcement failed on \(failures)/\(sockets) socket(s) (errno \(errno))", category: .extensions)
        }
    }

    private func startRegisterListenerIfNeeded() {
        guard registerListener == nil else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.includePeerToPeer = true

            let listener = try NWListener(
                using: params,
                on: NWEndpoint.Port(integerLiteral: NWEndpoint.Port.IntegerLiteralType(defaultPort))
            )

            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    Task { @MainActor [weak self] in
                        Logger.log("LocalSend register listener failed: \(error.localizedDescription)", category: .extensions)
                        self?.registerListener = nil
                    }
                }
            }

            // Every connection is served by the receive service's HTTP router: it
            // streams uploads straight to disk and delegates register/info back
            // here (a single `receive` used to truncate segmented requests).
            listener.newConnectionHandler = { connection in
                LocalSendReceiveService.shared.accept(connection)
            }

            listener.start(queue: .global(qos: .utility))
            registerListener = listener
        } catch {
            Logger.log("LocalSend register listener start failed: \(error.localizedDescription)", category: .extensions)
        }
    }

    /// Answers a fully read request that the receive service routed here.
    func registerResponse(forRequest data: Data, from endpoint: NWEndpoint) -> Data {
        guard let request = String(data: data, encoding: .utf8) else {
            return httpResponse(status: 400, json: ["error": "invalid-request"])
        }

        let parts = request.components(separatedBy: "\r\n\r\n")
        guard let head = parts.first,
              let firstLine = head.components(separatedBy: "\r\n").first
        else {
            return httpResponse(status: 400, json: ["error": "invalid-request"])
        }

        let tokens = firstLine.split(separator: " ")
        guard tokens.count >= 2 else {
            return httpResponse(status: 400, json: ["error": "invalid-request"])
        }

        let method = String(tokens[0]).uppercased()
        let rawPath = String(tokens[1])
        let path = rawPath.components(separatedBy: "?").first ?? rawPath

        if method == "POST", path == "/api/localsend/v2/register" || path == "/api/localsend/v3/register" {
            let callerIP = endpointIPv4(endpoint)
            let bodyText = parts.dropFirst().joined(separator: "\r\n\r\n")
            let bodyData = bodyText.data(using: .utf8)
            let json = bodyData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

            if let json,
               let fingerprint = json["fingerprint"] as? String,
               let alias = json["alias"] as? String,
               let callerIP,
               fingerprint != "atoll.localsend.bridge" {
                let device = LocalSendDeviceInfo(
                    id: fingerprint,
                    alias: alias,
                    ip: callerIP,
                    port: (json["port"] as? Int) ?? defaultPort,
                    https: (json["protocol"] as? String) == "https",
                    model: json["deviceModel"] as? String
                )
                discoveredByID[fingerprint] = (device, Date())
                rememberKnownPeerIP(callerIP)
                rememberRecentProbeIP(callerIP)
                refreshDevices()
            } else if let callerIP {
                // Be tolerant to partial HTTP payloads: still ACK register and probe caller directly.
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let device = await Self.probeDeviceInfo(at: callerIP, port: defaultPort, timeout: 0.35) {
                        self.discoveredByID[device.id] = (device, Date())
                        self.rememberKnownPeerIP(device.ip)
                        self.rememberRecentProbeIP(device.ip)
                        self.refreshDevices()
                    }
                }
            }

            let responseJSON: [String: Any] = [
                "alias": Host.current().localizedName ?? "Atoll",
                "version": "2.1",
                "deviceModel": "Mac",
                "deviceType": "desktop",
                "token": "atoll.localsend.bridge",
                "fingerprint": "atoll.localsend.bridge",
                "download": false,
                "hasWebInterface": false,
            ]
            return httpResponse(status: 200, json: responseJSON)
        }

        if method == "GET", path == "/api/localsend/v2/info" {
            let responseJSON: [String: Any] = [
                "alias": Host.current().localizedName ?? "Atoll",
                "version": "2.1",
                "deviceModel": "Mac",
                "deviceType": "desktop",
                "fingerprint": "atoll.localsend.bridge",
                "port": defaultPort,
                "protocol": "http",
                "download": false,
            ]
            return httpResponse(status: 200, json: responseJSON)
        }

        return httpResponse(status: 404, json: ["error": "not-found"])
    }

    private func endpointIPv4(_ endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else { return nil }
        let ip = host.debugDescription.replacingOccurrences(of: "\"", with: "")
        return isValidIPv4(ip) ? ip : nil
    }

    private func httpResponse(status: Int, json: [String: Any]) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
        let headers = [
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")",
            "Content-Type: application/json",
            "Content-Length: \(body.count)",
            "Connection: close",
            "",
            "",
        ].joined(separator: "\r\n")

        var response = Data(headers.utf8)
        response.append(body)
        return response
    }

    private func handleIncoming(content: Data, endpoint: NWEndpoint?) {
        guard let json = try? JSONSerialization.jsonObject(with: content) as? [String: Any],
              let fingerprint = json["fingerprint"] as? String,
              let alias = json["alias"] as? String
        else { return }

        if fingerprint == "atoll.localsend.bridge" { return }

        // Trust only the source address: upstream announcements carry no "ip"
        // field (checked against LocalSend v1.18.2's DTOs), so honouring one would
        // just let a peer point us at a different host.
        guard case let .hostPort(host, _) = endpoint else { return }
        let ip = host.debugDescription.replacingOccurrences(of: "\"", with: "")
        guard isValidIPv4(ip) else { return }

        let port = (json["port"] as? Int) ?? defaultPort
        let https = (json["protocol"] as? String) == "https"
        let model = json["deviceModel"] as? String

        let device = LocalSendDeviceInfo(
            id: fingerprint,
            alias: alias,
            ip: ip,
            port: port,
            https: https,
            model: model
        )

        discoveredByID[fingerprint] = (device, Date())
        rememberKnownPeerIP(ip)
        rememberRecentProbeIP(ip)
        refreshDevices()
    }

    private func cleanupStale() {
        let cutoff = Date().addingTimeInterval(-30)
        discoveredByID = discoveredByID.filter { $0.value.lastSeen > cutoff }
        refreshDevices()
        // Pruning can empty the list while nothing else is happening; re-arm the
        // idle timer here, otherwise discovery (sockets, 8 s announcements, the
        // 53317 listener) would keep running until the app quits.
        scheduleIdleStopIfIdle()
    }

    private func refreshDevices() {
        devices = discoveredByID.values.map(\.device).sorted { $0.alias.localizedCaseInsensitiveCompare($1.alias) == .orderedAscending }
        if !devices.contains(where: { $0.id == selectedDeviceID }), let first = devices.first {
            selectedDeviceID = first.id
        }
    }

    private struct TransferFile: Sendable {
        let id: String
        let name: String
        let mimeType: String
        let data: Data
    }

    /// Lowercase-hex SHA-256 of every file, computed concurrently off the actor.
    private nonisolated static func sha256HexDigests(for files: [TransferFile]) async -> [String: String] {
        await withTaskGroup(of: (String, String).self) { group in
            for file in files {
                group.addTask {
                    let digest = SHA256.hash(data: file.data)
                        .map { String(format: "%02x", $0) }
                        .joined()
                    return (file.id, digest)
                }
            }
            var result: [String: String] = [:]
            for await (id, digest) in group {
                result[id] = digest
            }
            return result
        }
    }

    private func buildTransferFiles(from items: [Any]) async throws -> [TransferFile] {
        var result: [TransferFile] = []
        for item in items {
            if let url = item as? URL, url.isFileURL {
                if let data = try? Data(contentsOf: url) {
                    result.append(TransferFile(
                        id: UUID().uuidString,
                        name: url.lastPathComponent,
                        mimeType: preferredTransferMimeType(for: url),
                        data: data
                    ))
                }
            } else if let url = item as? URL {
                let string = url.absoluteString
                result.append(TransferFile(
                    id: UUID().uuidString,
                    name: "link.url",
                    mimeType: "text/uri-list",
                    data: Data(string.utf8)
                ))
            } else if let text = item as? String {
                result.append(TransferFile(
                    id: UUID().uuidString,
                    name: "text.txt",
                    mimeType: "text/plain",
                    data: Data(text.utf8)
                ))
            }
        }
        return result
    }

    private func preferredTransferMimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "svg" {
            // Some LocalSend receivers try gallery/image-specific write paths for SVG and fail.
            return "application/octet-stream"
        }
        return url.mimeType ?? "application/octet-stream"
    }

    private func prepareUpload(files: [TransferFile], to device: LocalSendDeviceInfo) async throws -> (sessionID: String, fileTokens: [String: String]) {
        // SHA-256 checksums (protocol v2.2) are computed off the main actor: the
        // hash runs at a few GB/s, so hashing inline froze the UI for roughly
        // 0.4 s per GB of payload.
        let digests = await Self.sha256HexDigests(for: files)

        var filesMap: [String: Any] = [:]
        for file in files {
            var entry: [String: Any] = [
                "id": file.id,
                "fileName": file.name,
                "size": file.data.count,
                "fileType": file.mimeType,
            ]
            // Only claim a checksum we actually computed: receivers that verify it
            // answer 422 on a mismatch.
            if let digest = digests[file.id] {
                entry["sha256"] = digest
            }
            filesMap[file.id] = entry
        }

        let payload: [String: Any] = [
            "info": [
                "alias": Host.current().localizedName ?? "Atoll",
                "version": "2.1",
                "deviceModel": "Mac",
                "deviceType": "desktop",
                "fingerprint": "atoll.localsend.bridge",
                "token": "atoll.localsend.bridge",
                "port": defaultPort,
                "protocol": device.https ? "https" : "http",
                "download": false,
            ],
            "files": filesMap,
        ]

        var lastError: Error?
        for baseURL in candidateBaseURLs(for: device) {
            do {
                return try await prepareUpload(payload: payload, baseURL: baseURL, deviceName: device.displayName)
            } catch {
                lastError = error
                Logger.log("LocalSend prepare-upload failed via \(baseURL): \(error.localizedDescription)", category: .extensions)
                if !shouldRetryAcrossSchemes(error) {
                    throw error
                }
            }
        }

        throw lastError ?? LocalSendServiceError.invalidResponse
    }

    private func prepareUpload(payload: [String: Any], baseURL: String, deviceName: String) async throws -> (sessionID: String, fileTokens: [String: String]) {
        guard let url = URL(string: "\(baseURL)/api/localsend/v2/prepare-upload") else {
            throw LocalSendServiceError.invalidTarget
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await trustedSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LocalSendServiceError.invalidResponse }

        if http.statusCode == 204 {
            return ("", [:])
        }
        // HTTP 403 means the transfer was rejected by the recipient
        if http.statusCode == 403 {
            throw LocalSendServiceError.transferRejected
        }
        // HTTP 401 means the receiver requires a PIN (protocol v2.1)
        if http.statusCode == 401 {
            throw LocalSendServiceError.pinRequired(deviceName: deviceName)
        }
        guard (200 ... 299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw LocalSendServiceError.server(status: http.statusCode, body: body)
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = json["sessionId"] as? String,
              let rawFileTokens = json["files"] as? [String: Any]
        else { throw LocalSendServiceError.invalidResponse }

        var fileTokens: [String: String] = [:]
        for (k, v) in rawFileTokens {
            if let s = v as? String {
                fileTokens[k] = s
            }
        }

        return (sessionID, fileTokens)
    }

    private func upload(file: TransferFile, sessionID: String, token: String, to device: LocalSendDeviceInfo, progress: @escaping (Double) -> Void) async throws {
        var lastError: Error?
        for baseURL in candidateBaseURLs(for: device) {
            do {
                try await upload(file: file, sessionID: sessionID, token: token, baseURL: baseURL, progress: progress)
                return
            } catch {
                lastError = error
                Logger.log("LocalSend upload failed via \(baseURL) for \(file.name): \(error.localizedDescription)", category: .extensions)
                if !shouldRetryAcrossSchemes(error) {
                    throw error
                }
            }
        }
        throw lastError ?? LocalSendServiceError.invalidResponse
    }

    private func upload(file: TransferFile, sessionID: String, token: String, baseURL: String, progress: @escaping (Double) -> Void) async throws {
        var components = URLComponents(string: "\(baseURL)/api/localsend/v2/upload")
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionID),
            URLQueryItem(name: "fileId", value: file.id),
            URLQueryItem(name: "token", value: token),
        ]

        guard let url = components?.url else { throw LocalSendServiceError.invalidTarget }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(file.mimeType, forHTTPHeaderField: "Content-Type")
        request.setValue("\(file.data.count)", forHTTPHeaderField: "Content-Length")

        // Use uploadTask to receive per-byte progress via delegate
        let delegate = UploadProgressDelegate { sent, expected in
            guard expected > 0 else { return }
            let fraction = Double(sent) / Double(expected)
            progress(fraction)
        }

        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        // Invalidate on every exit path, not just the successful one: an upload
        // that throws used to leave the session (and its delegate) un-invalidated.
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
            let task = session.uploadTask(with: request, from: file.data) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let data = data, let response = response else {
                    continuation.resume(throwing: LocalSendServiceError.invalidResponse)
                    return
                }
                continuation.resume(returning: (data, response))
            }
            task.resume()
        }

        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8)
            throw LocalSendServiceError.server(status: status, body: body)
        }
    }

    private func candidateBaseURLs(for device: LocalSendDeviceInfo) -> [String] {
        let primary = device.baseURL
        let alternateScheme = device.https ? "http" : "https"
        let alternate = "\(alternateScheme)://\(device.ip):\(device.port)"
        return primary == alternate ? [primary] : [primary, alternate]
    }

    private func shouldRetryAcrossSchemes(_ error: Error) -> Bool {
        if case LocalSendServiceError.server = error {
            // A peer responded with a concrete HTTP error; fallback to another scheme is usually noise.
            return false
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            switch code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotFindHost, .cannotConnectToHost, .secureConnectionFailed,
                 .dnsLookupFailed:
                return true
            default:
                return false
            }
        }

        return false
    }

    private lazy var trustedSession: URLSession = {
        URLSession(configuration: .default, delegate: LocalSendTLSDelegate(), delegateQueue: nil)
    }()

    /// Text for a failure against an encrypted peer that the raw `URLError`
    /// description explains badly, or nil when the raw description should stand.
    /// Only TLS-shaped codes are mapped: a plain reachability error keeps its own
    /// wording, and reliability-only failures are not blamed on encryption.
    private func transferFailureMessage(for error: Error, target: LocalSendDeviceInfo?) -> String? {
        guard let target, target.https else { return nil }
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        switch URLError.Code(rawValue: nsError.code) {
        case .networkConnectionLost, .secureConnectionFailed, .clientCertificateRejected:
            return """
            Could not finish the encrypted handshake with \(target.alias): either its LocalSend encryption rejected Atoll's client certificate, or the connection to it dropped. Turning off “Encryption” on that device (Settings → Network) avoids the certificate path entirely.
            """
        default:
            return nil
        }
    }
}

/// Carries the user-facing text for a failed transfer. `send(items:)` throws this
/// when the raw `URLError` description would mislead, because the callers alert
/// with `error.localizedDescription` (see `QuickShareService`).
private struct LocalSendTransferFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private class LocalSendTLSDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        // Encrypted LocalSend peers ask for a client certificate during the handshake.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodClientCertificate {
            guard let identity = LocalSendIdentity.identity() else { return (.performDefaultHandling, nil) }
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else {
                return (.performDefaultHandling, nil)
            }
            return (.useCredential, URLCredential(identity: identity, certificates: [certificate], persistence: .none))
        }
        if let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

/// The client identity Atoll presents to LocalSend peers.
///
/// Peers with encryption enabled run their HTTP server with mutual TLS and
/// require a client certificate (upstream only checks that the certificate is
/// valid, not which one it is), so sending to them needs a self-signed identity
/// of our own. It is generated once with the system openssl and then reused.
private enum LocalSendIdentity {
    /// Protects the p12 file only; the file itself is stored 0600.
    private static let passphrase = "atoll-localsend"
    private static let lock = NSLock()
    private static var cached: SecIdentity?
    /// When the last generation attempt was made. Generating runs three openssl
    /// subprocesses, so a failure backs off instead of retrying on every
    /// handshake — but it does retry (a transient failure must not need an app
    /// relaunch to recover).
    private static var lastAttempt: Date?
    private static let attemptCooldown: TimeInterval = 60

    static func identity() -> SecIdentity? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        // Reading the stored p12 is cheap and safe to retry, so a transient file
        // or keychain error does not poison the process.
        if let stored = load() {
            cached = stored
            return stored
        }
        if let lastAttempt, Date().timeIntervalSince(lastAttempt) < attemptCooldown {
            return nil
        }
        lastAttempt = Date()
        let identity = generate()
        cached = identity
        return identity
    }

    private static let p12URL: URL? = {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let directory = base
            .appendingPathComponent("DynamicIsland", isDirectory: true)
            .appendingPathComponent("LocalSend", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Earlier builds stored a v1 certificate under this name, which rustls rejects.
        try? FileManager.default.removeItem(at: directory.appendingPathComponent("localsend-identity.p12"))
        return directory.appendingPathComponent("localsend-identity-v3.p12")
    }()

    private static func load() -> SecIdentity? {
        guard let p12URL, let data = try? Data(contentsOf: p12URL) else { return nil }

        var options: [String: Any] = [kSecImportExportPassphrase as String: passphrase]
        if #available(macOS 15.0, *) {
            // Keep the identity in memory instead of adding it to the login keychain.
            options[kSecImportToMemoryOnly as String] = true
        }
        // On macOS 14 and older the identity is imported into the default
        // keychain, which is the only path available there.

        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess,
              let imported = items as? [[String: Any]]
        else {
            Logger.log("LocalSend client identity could not be read from the stored p12 (OSStatus \(status))", category: .extensions)
            return nil
        }

        for item in imported {
            if let value = item[kSecImportItemIdentity as String] {
                return (value as! SecIdentity)
            }
        }
        return nil
    }

    private static func generate() -> SecIdentity? {
        let opensslPath = "/usr/bin/openssl"
        guard let p12URL, FileManager.default.isExecutableFile(atPath: opensslPath) else {
            Logger.log("LocalSend client identity unavailable (\(opensslPath) is missing)", category: .extensions)
            return nil
        }

        let directory = p12URL.deletingLastPathComponent()
        let staging = directory.appendingPathComponent("identity-staging", isDirectory: true)
        try? FileManager.default.removeItem(at: staging)
        guard (try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)) != nil else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let keyURL = staging.appendingPathComponent("key.pem")
        let requestURL = staging.appendingPathComponent("request.csr")
        let certificateURL = staging.appendingPathComponent("certificate.pem")
        let configURL = staging.appendingPathComponent("ca.cnf")
        try? FileManager.default.createDirectory(
            at: staging.appendingPathComponent("newcerts", isDirectory: true),
            withIntermediateDirectories: true
        )
        _ = FileManager.default.createFile(atPath: staging.appendingPathComponent("index.txt").path, contents: nil)
        try? "01".write(to: staging.appendingPathComponent("serial"), atomically: true, encoding: .utf8)

        // Two properties matter for the certificate, both learned the hard way:
        // - It must be X.509 v3. LocalSend 1.18+ verifies client certificates
        //   with rustls/webpki, which rejects v1 ("UnsupportedCertVersion");
        //   `openssl req -x509` without extensions emits v1.
        // - It must not start in the future. The peer checks `notBefore` against
        //   its own clock, which can lag ours by a second, so a certificate
        //   created inside the handshake gets rejected as "not yet valid"
        //   (rustls reports that as `access denied`). Upstream LocalSend
        //   generates identities valid from 1975 for the same reason, so this
        //   uses `openssl ca -selfsign -startdate` instead of `req -x509`.
        let config = """
        [ca]
        default_ca = CA_default

        [CA_default]
        dir = \(staging.path)
        database = $dir/index.txt
        new_certs_dir = $dir/newcerts
        serial = $dir/serial
        private_key = $dir/key.pem
        default_md = sha256
        policy = policy_any
        x509_extensions = v3_client
        unique_subject = no

        [policy_any]
        commonName = supplied

        [v3_client]
        basicConstraints = critical,CA:FALSE
        keyUsage = critical,digitalSignature,keyEncipherment
        extendedKeyUsage = clientAuth

        [req]
        distinguished_name = dn
        prompt = no

        [dn]
        CN = LocalSend User
        """
        do {
            try config.write(to: configURL, atomically: true, encoding: .utf8)
        } catch {
            Logger.log("LocalSend client identity: config write failed (\(error.localizedDescription))", category: .extensions)
            return nil
        }

        // Same identity shape as upstream LocalSend: RSA-2048, CN=LocalSend User.
        guard runOpenSSL(opensslPath, [
            "req", "-new", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyURL.path,
            "-out", requestURL.path,
            "-config", configURL.path,
        ]), runOpenSSL(opensslPath, [
            "ca", "-selfsign", "-batch", "-notext",
            "-config", configURL.path,
            "-startdate", "19750101000000Z",
            "-enddate", "40960101000000Z",
            "-extensions", "v3_client",
            "-keyfile", keyURL.path,
            "-in", requestURL.path,
            "-out", certificateURL.path,
        ]), runOpenSSL(opensslPath, [
            "pkcs12", "-export", "-out", p12URL.path,
            "-inkey", keyURL.path,
            "-in", certificateURL.path,
            "-passout", "pass:\(passphrase)",
        ]) else { return nil }

        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12URL.path)
        Logger.log("LocalSend client identity generated for encrypted peers", category: .extensions)
        return load()
    }

    private static func runOpenSSL(_ path: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            Logger.log("LocalSend client identity: openssl failed (\(error.localizedDescription))", category: .extensions)
            return false
        }
        guard process.terminationStatus == 0 else {
            Logger.log("LocalSend client identity: openssl exited with \(process.terminationStatus)", category: .extensions)
            return false
        }
        return true
    }
}

private final class UploadProgressDelegate: LocalSendTLSDelegate, URLSessionTaskDelegate {
    private let onProgress: (Int64, Int64) -> Void

    init(onProgress: @escaping (Int64, Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Task { @MainActor in
            onProgress(totalBytesSent, totalBytesExpectedToSend)
        }
    }
}

private extension URL {
    var mimeType: String? {
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension)
        else { return nil }
        return type.preferredMIMEType
    }
}

enum LocalSendServiceError: LocalizedError {
    case noDeviceSelected
    case noTransferableItems
    case invalidTarget
    case invalidResponse
    case server(status: Int, body: String?)
    case transferRejected
    case pinRequired(deviceName: String)

    var errorDescription: String? {
        switch self {
        case .noDeviceSelected:
            return "No LocalSend device selected"
        case .noTransferableItems:
            return "No transferable files or text found"
        case .invalidTarget:
            return "Invalid LocalSend target"
        case .invalidResponse:
            return "Invalid response from LocalSend peer"
        case .server(let status, let body):
            if let body, !body.isEmpty {
                return "LocalSend peer error (\(status)): \(body)"
            }
            return "LocalSend peer error (\(status))"
        case .transferRejected:
            return "Transfer was rejected by the recipient"
        case .pinRequired(let deviceName):
            return "\(deviceName) requires a PIN. Disable the PIN on the receiving device, or accept the transfer there by entering the PIN."
        }
    }
}