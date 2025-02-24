// SPDX-License-Identifier: MIT
// Copyright © 2018-2020 WireGuard LLC. All Rights Reserved.

import Foundation
import NetworkExtension

#if SWIFT_PACKAGE
import WireGuardKitGo
#endif

public enum WireGuardAdapterError: Error {
    /// Failure to locate tunnel file descriptor.
    case cannotLocateTunnelFileDescriptor

    /// Failure to perform an operation in such state.
    case invalidState

    /// Failure to resolve endpoints.
    case dnsResolution([DNSResolutionError])

    /// Failure to set network settings.
    case setNetworkSettings(Error)

    /// Failure to start WireGuard backend.
    case startWireGuardBackend(Int32)
}

/// Enum representing internal state of the `WireGuardAdapter`
private enum State {
    /// The tunnel is stopped
    case stopped

    /// The tunnel is up and running
    case started(_ handle: Int32, _ settingsGenerator: PacketTunnelSettingsGenerator)

    /// The tunnel is temporarily shutdown due to device going offline
    case temporaryShutdown(_ settingsGenerator: PacketTunnelSettingsGenerator)
}

public class WireGuardAdapter {
    public typealias LogHandler = (WireGuardLogLevel, String) -> Void

    /// Network routes monitor.
    private var networkMonitor: NWPathMonitor?

    /// Packet tunnel provider.
    private weak var packetTunnelProvider: NEPacketTunnelProvider?

    /// Log handler closure.
    private let logHandler: LogHandler

    /// Private queue used to synchronize access to `WireGuardAdapter` members.
    private let workQueue = DispatchQueue(label: "WireGuardAdapterWorkQueue")

    /// Adapter state.
    private var state: State = .stopped

    /// Tunnel device file descriptor.
    private var tunnelFileDescriptor: Int32? {
        return self.packetTunnelProvider?.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32
    }

    /// Returns a WireGuard version.
    class var backendVersion: String {
        guard let ver = wgVersion() else { return "unknown" }
        let str = String(cString: ver)
        free(UnsafeMutableRawPointer(mutating: ver))
        return str
    }

    /// Returns the tunnel device interface name, or nil on error.
    /// - Returns: String.
    public var interfaceName: String? {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(IFNAMSIZ))

        return buffer.withUnsafeMutableBufferPointer { mutableBufferPointer in
            guard let baseAddress = mutableBufferPointer.baseAddress else { return nil }

            var ifnameSize = socklen_t(IFNAMSIZ)
            let result = getsockopt(
                tunnelFileDescriptor,
                2 /* SYSPROTO_CONTROL */,
                2 /* UTUN_OPT_IFNAME */,
                baseAddress,
                &ifnameSize)

            if result == 0 {
                return String(cString: baseAddress)
            } else {
                return nil
            }
        }
    }

    // MARK: - Initialization

    /// Designated initializer.
    /// - Parameter packetTunnelProvider: an instance of `NEPacketTunnelProvider`. Internally stored
    ///   as a weak reference.
    /// - Parameter logHandler: a log handler closure.
    public init(with packetTunnelProvider: NEPacketTunnelProvider, logHandler: @escaping LogHandler) {
        self.packetTunnelProvider = packetTunnelProvider
        self.logHandler = logHandler

        setupLogHandler()
    }

    deinit {
        // Force remove logger to make sure that no further calls to the instance of this class
        // can happen after deallocation.
        wgSetLogger(nil, nil)

        // Cancel network monitor
        networkMonitor?.cancel()

        // Shutdown the tunnel
        if case .started(let handle, _) = self.state {
            wgTurnOff(handle)
        }
    }

    // MARK: - Public methods

    /// Returns a runtime configuration from WireGuard.
    /// - Parameter completionHandler: completion handler.
    public func getRuntimeConfiguration(completionHandler: @escaping (String?) -> Void) {
        workQueue.async {
            guard case .started(let handle, _) = self.state else {
                completionHandler(nil)
                return
            }

            if let settings = wgGetConfig(handle) {
                completionHandler(String(cString: settings))
                free(settings)
            } else {
                completionHandler(nil)
            }
        }
    }

    /// Start the tunnel tunnel.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    public func start(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            guard case .stopped = self.state else {
                completionHandler(.invalidState)
                return
            }

            let networkMonitor = NWPathMonitor()
            networkMonitor.pathUpdateHandler = { [weak self] path in
                self?.didReceivePathUpdate(path: path)
            }
            networkMonitor.start(queue: self.workQueue)

            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                self.state = .started(
                    try self.startWireGuardBackend(wgConfig: wgConfig),
                    settingsGenerator
                )
                self.networkMonitor = networkMonitor
                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                networkMonitor.cancel()
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    /// Stop the tunnel.
    /// - Parameter completionHandler: completion handler.
    public func stop(completionHandler: @escaping (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            switch self.state {
            case .started(let handle, _):
                wgTurnOff(handle)

            case .temporaryShutdown:
                break

            case .stopped:
                completionHandler(.invalidState)
                return
            }

            self.networkMonitor?.cancel()
            self.networkMonitor = nil

            self.state = .stopped

            completionHandler(nil)
        }
    }

    /// Update runtime configuration.
    /// - Parameters:
    ///   - tunnelConfiguration: tunnel configuration.
    ///   - completionHandler: completion handler.
    public func update(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (WireGuardAdapterError?) -> Void) {
        workQueue.async {
            if case .stopped = self.state {
                completionHandler(.invalidState)
                return
            }

            // Tell the system that the tunnel is going to reconnect using new WireGuard
            // configuration.
            // This will broadcast the `NEVPNStatusDidChange` notification to the GUI process.
            self.packetTunnelProvider?.reasserting = true
            defer {
                self.packetTunnelProvider?.reasserting = false
            }

            do {
                let settingsGenerator = try self.makeSettingsGenerator(with: tunnelConfiguration)
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                switch self.state {
                case .started(let handle, _):
                    let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                    self.logEndpointResolutionResults(resolutionResults)

                    wgSetConfig(handle, wgConfig)
                    #if os(iOS)
                    wgDisableSomeRoamingForBrokenMobileSemantics(handle)
                    #endif

                    self.state = .started(handle, settingsGenerator)

                case .temporaryShutdown:
                    self.state = .temporaryShutdown(settingsGenerator)

                case .stopped:
                    fatalError()
                }

                completionHandler(nil)
            } catch let error as WireGuardAdapterError {
                completionHandler(error)
            } catch {
                fatalError()
            }
        }
    }

    // MARK: - Private methods

    /// Setup WireGuard log handler.
    private func setupLogHandler() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        wgSetLogger(context) { context, logLevel, message in
            guard let context = context, let message = message else { return }

            let unretainedSelf = Unmanaged<WireGuardAdapter>.fromOpaque(context)
                .takeUnretainedValue()

            let swiftString = String(cString: message).trimmingCharacters(in: .newlines)
            let tunnelLogLevel = WireGuardLogLevel(rawValue: logLevel) ?? .verbose

            unretainedSelf.logHandler(tunnelLogLevel, swiftString)
        }
    }

    /// Set network tunnel configuration.
    /// This method ensures that the call to `setTunnelNetworkSettings` does not time out, as in
    /// certain scenarios the completion handler given to it may not be invoked by the system.
    ///
    /// - Parameters:
    ///   - networkSettings: an instance of type `NEPacketTunnelNetworkSettings`.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: `PacketTunnelSettingsGenerator`.
    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
        var systemError: Error?
        let condition = NSCondition()

        // Activate the condition
        condition.lock()
        defer { condition.unlock() }

        // https://www.ipdeny.com/ipblocks/

        let defaults = UserDefaults.standard

        var excludedRoutes = [NEIPv4Route]()
        var includedRoutes = [NEIPv4Route]()

        for routeType in ["includeCountries", "excludeCountries"] {
            let networkArray = defaults.object(forKey:routeType) as? [String] ?? [String]()

            for country in networkArray
            {
                NSLog("OVPN Country Routing: %@ %@", routeType, country)

                if let path = Bundle.main.path(forResource: country, ofType: "zone", inDirectory: "all-zones") {
                    do {
                        let data = try String(contentsOfFile: path, encoding: .utf8)
                        let myStrings = data.components(separatedBy: .newlines)
                        for line in myStrings {

                            let array = line.components(separatedBy: "/")
                            if(array.count < 2) {
                                continue
                            }

                            let destinationAddress = array[0]
                            let cidr = array[1]
                            let subnet = self.cidrToMask(cidr: cidr)
                            // NSLog(line.appending(subnet));

                            if(routeType == "excludeCountries") {
                                excludedRoutes.append(NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnet))
                            } else {
                                includedRoutes.append(NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnet))
                            }
                        }
                    } catch {
                        NSLog("OVPN No country files found")
                    }
                }
            }
        }

        // If we haven't set any specific includes then by default route everything over VPN
        // If we have set includes, then only send than and by defult dont route everything else

        if(includedRoutes.count < 1) {
            includedRoutes.append(NEIPv4Route .default())

            // If we're routing everything then exclude local networks
            // https://en.wikipedia.org/wiki/Reserved_IP_addresses

            let localNetworks = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
            for line in localNetworks {
                let array = line.components(separatedBy: "/")
                if(array.count < 2) {
                    continue
                }

                let destinationAddress = array[0]
                let cidr = array[1]
                let subnet = self.cidrToMask(cidr: cidr)
                excludedRoutes.append(NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnet))
            }

            let networkArray = defaults.object(forKey:"customRoutes") as? [String] ?? [String]()
            for line in networkArray {
                let array = line.components(separatedBy: "/")
                if(array.count < 2) {
                    continue
                }

                let destinationAddress = array[0]
                let cidr = array[1]
                let subnet = self.cidrToMask(cidr: cidr)
                excludedRoutes.append(NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnet))
                NSLog("OVPN Excluded Custom Route: %@", line)
            }
        } else {
            excludedRoutes.append(NEIPv4Route .default())
            let networkArray = defaults.object(forKey:"customRoutes") as? [String] ?? [String]()
            for line in networkArray {
                let array = line.components(separatedBy: "/")
                if(array.count < 2) {
                    continue
                }

                let destinationAddress = array[0]
                let cidr = array[1]
                let subnet = self.cidrToMask(cidr: cidr)
                includedRoutes.append(NEIPv4Route(destinationAddress: destinationAddress, subnetMask: subnet))
                NSLog("OVPN Included Custom Route: %@", line)
            }

            //settings.ipv4Settings?.excludedRoutes = [NEIPv4Route(destinationAddress: "107.191.37.75", subnetMask: "255.255.255.255")]

        }

        NSLog("OVPN Included Routes: %d", includedRoutes.count)
        NSLog("OVPN Excluded Routes: %d", excludedRoutes.count)

        networkSettings.ipv4Settings?.excludedRoutes = excludedRoutes
        networkSettings.ipv4Settings?.includedRoutes = includedRoutes

        self.packetTunnelProvider?.setTunnelNetworkSettings(networkSettings) { error in
            systemError = error
            condition.signal()
        }

        // Packet tunnel's `setTunnelNetworkSettings` times out in certain
        // scenarios & never calls the given callback.
        let setTunnelNetworkSettingsTimeout: TimeInterval = 5 // seconds

        if condition.wait(until: Date().addingTimeInterval(setTunnelNetworkSettingsTimeout)) {
            if let systemError = systemError {
                throw WireGuardAdapterError.setNetworkSettings(systemError)
            }
        } else {
            self.logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
        }
    }

    /// Resolve peers of the given tunnel configuration.
    /// - Parameter tunnelConfiguration: tunnel configuration.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: The list of resolved endpoints.
    private func resolvePeers(for tunnelConfiguration: TunnelConfiguration) throws -> [Endpoint?] {
        let endpoints = tunnelConfiguration.peers.map { $0.endpoint }
        let resolutionResults = DNSResolver.resolveSync(endpoints: endpoints)
        let resolutionErrors = resolutionResults.compactMap { result -> DNSResolutionError? in
            if case .failure(let error) = result {
                return error
            } else {
                return nil
            }
        }
        assert(endpoints.count == resolutionResults.count)
        guard resolutionErrors.isEmpty else {
            throw WireGuardAdapterError.dnsResolution(resolutionErrors)
        }

        let resolvedEndpoints = resolutionResults.map { result -> Endpoint? in
            // swiftlint:disable:next force_try
            return try! result?.get()
        }

        return resolvedEndpoints
    }

    /// Start WireGuard backend.
    /// - Parameter wgConfig: WireGuard configuration
    /// - Throws: an error of type `WireGuardAdapterError`
    /// - Returns: tunnel handle
    private func startWireGuardBackend(wgConfig: String) throws -> Int32 {
        guard let tunnelFileDescriptor = self.tunnelFileDescriptor else {
            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor
        }

        let handle = wgTurnOn(wgConfig, tunnelFileDescriptor)
        if handle < 0 {
            throw WireGuardAdapterError.startWireGuardBackend(handle)
        }
        #if os(iOS)
        wgDisableSomeRoamingForBrokenMobileSemantics(handle)
        #endif
        return handle
    }

    /// Resolves the hostnames in the given tunnel configuration and return settings generator.
    /// - Parameter tunnelConfiguration: an instance of type `TunnelConfiguration`.
    /// - Throws: an error of type `WireGuardAdapterError`.
    /// - Returns: an instance of type `PacketTunnelSettingsGenerator`.
    private func makeSettingsGenerator(with tunnelConfiguration: TunnelConfiguration) throws -> PacketTunnelSettingsGenerator {
        return PacketTunnelSettingsGenerator(
            tunnelConfiguration: tunnelConfiguration,
            resolvedEndpoints: try self.resolvePeers(for: tunnelConfiguration)
        )
    }

    /// Log DNS resolution results.
    /// - Parameter resolutionErrors: an array of type `[DNSResolutionError]`.
    private func logEndpointResolutionResults(_ resolutionResults: [EndpointResolutionResult?]) {
        for case .some(let result) in resolutionResults {
            switch result {
            case .success((let sourceEndpoint, let resolvedEndpoint)):
                if sourceEndpoint.host == resolvedEndpoint.host {
                    self.logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to itself.")
                } else {
                    self.logHandler(.verbose, "DNS64: mapped \(sourceEndpoint.host) to \(resolvedEndpoint.host)")
                }
            case .failure(let resolutionError):
                self.logHandler(.error, "Failed to resolve endpoint \(resolutionError.address): \(resolutionError.errorDescription ?? "(nil)")")
            }
        }
    }

    /// Helper method used by network path monitor.
    /// - Parameter path: new network path
    private func didReceivePathUpdate(path: Network.NWPath) {
        self.logHandler(.verbose, "Network change detected with \(path.status) route and interface order \(path.availableInterfaces)")

        #if os(macOS)
        if case .started(let handle, _) = self.state {
            wgBumpSockets(handle)
        }
        #elseif os(iOS)
        switch self.state {
        case .started(let handle, let settingsGenerator):
            if path.status.isSatisfiable {
                let (wgConfig, resolutionResults) = settingsGenerator.endpointUapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                wgSetConfig(handle, wgConfig)
                wgDisableSomeRoamingForBrokenMobileSemantics(handle)
                wgBumpSockets(handle)
            } else {
                self.logHandler(.verbose, "Connectivity offline, pausing backend.")

                self.state = .temporaryShutdown(settingsGenerator)
                wgTurnOff(handle)
            }

        case .temporaryShutdown(let settingsGenerator):
            guard path.status.isSatisfiable else { return }

            self.logHandler(.verbose, "Connectivity online, resuming backend.")

            do {
                try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())

                let (wgConfig, resolutionResults) = settingsGenerator.uapiConfiguration()
                self.logEndpointResolutionResults(resolutionResults)

                self.state = .started(
                    try self.startWireGuardBackend(wgConfig: wgConfig),
                    settingsGenerator
                )
            } catch {
                self.logHandler(.error, "Failed to restart backend: \(error.localizedDescription)")
            }

        case .stopped:
            // no-op
            break
        }
        #else
        #error("Unsupported")
        #endif
    }


    func cidrToMask(cidr: String) -> String {
        var subnet = "255.255.255.0"

        // Convert CIDR format to subnet
        switch cidr {
            case "1":subnet="128.0.0.0"
            case "2":subnet="192.0.0.0"
            case "3":subnet="224.0.0.0"
            case "4":subnet="240.0.0.0"
            case "5":subnet="248.0.0.0"
            case "6":subnet="252.0.0.0"
            case "7":subnet="254.0.0.0"
            case "8":subnet="255.0.0.0"
            case "9":subnet="255.128.0.0"
            case "10":subnet="255.192.0.0"
            case "11":subnet="255.224.0.0"
            case "12":subnet="255.240.0.0"
            case "13":subnet="255.248.0.0"
            case "14":subnet="255.252.0.0"
            case "15":subnet="255.254.0.0"
            case "16":subnet="255.255.0.0"
            case "17":subnet="255.255.128.0"
            case "18":subnet="255.255.192.0"
            case "19":subnet="255.255.224.0"
            case "20":subnet="255.255.240.0"
            case "21":subnet="255.255.248.0"
            case "22":subnet="255.255.252.0"
            case "23":subnet="255.255.254.0"
            case "24":subnet="255.255.255.0"
            case "25":subnet="255.255.255.128"
            case "26":subnet="255.255.255.192"
            case "27":subnet="255.255.255.224"
            case "28":subnet="255.255.255.240"
            case "29":subnet="255.255.255.248"
            case "30":subnet="255.255.255.252"
            case "31":subnet="255.255.255.254"
            case "32":subnet="255.255.255.255"
            default:subnet="255.255.255.255"
        }

        return subnet
    }
}

/// A enum describing WireGuard log levels defined in `api-ios.go`.
public enum WireGuardLogLevel: Int32 {
    case verbose = 0
    case error = 1
}

private extension Network.NWPath.Status {
    /// Returns `true` if the path is potentially satisfiable.
    var isSatisfiable: Bool {
        switch self {
        case .requiresConnection, .satisfied:
            return true
        case .unsatisfied:
            return false
        @unknown default:
            return true
        }
    }
}
