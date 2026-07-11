//
//  NetworkP2P.swift
//
//  Network-framework replacement for the MultipeerConnectivity engine.
//
//  Why: on iOS 26, MCSession establishment reliably fails over peer-to-peer
//  WiFi (AWDL) — invitations are delivered and accepted, but the data link
//  never forms and the OS gives up after ~10s. The same radio path works
//  via NWListener/NWBrowser with includePeerToPeer, so this class provides
//  the same behavior over the Network framework while keeping the plugin's
//  method-channel contract identical: the Dart side is unchanged.
//
//  Wire model:
//  - Discovery: NWListener advertises Bonjour "_<serviceType>n._tcp" (the
//    trailing "n" keeps old MPC builds and this engine invisible to each
//    other); NWBrowser lists peers by service name.
//  - Connect ("invite"): the inviter opens two TCP-over-AWDL connections to
//    the peer — a command channel and a frame channel.
//  - Framing: every message is [UInt32 big-endian length][payload]; TCP is a
//    byte stream, so this restores the atomic-message semantics the Dart
//    side expects (MPC messages were atomic).
//  - Intro: the first framed message on each outgoing connection is
//    [channel tag byte][sender name utf8], so the acceptor knows who
//    connected and on which logical channel. Tags match the old marker
//    scheme: 0x03 command, 0x02 frame.
//

import Flutter
import Foundation
import Network
import UIKit

@available(iOS 13.0, *)
class NetworkP2PManager {
    static let instance = NetworkP2PManager()

    static let commandTag: UInt8 = 0x03
    static let frameTag: UInt8 = 0x02

    // notConnected / connecting / connected — must match the Dart
    // SessionState enum (and MCSessionState) ordering.
    private static let stateNotConnected = 0
    private static let stateConnecting = 1
    private static let stateConnected = 2

    class Peer {
        var state = NetworkP2PManager.stateConnecting
        var command: FramedChannel?
        var frame: FramedChannel?
        var connectTimeout: DispatchWorkItem?
    }

    /// Set by the plugin: (method, arguments) -> invokeMethod on the main
    /// thread. All engine->Dart traffic goes through this.
    var emit: ((String, Any?) -> Void)?

    private let queue = DispatchQueue(label: "saycheese.networkp2p")
    private var myName = ""
    private var bonjourType = ""
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var discovered: [String: NWEndpoint] = [:]
    private var peers: [String: Peer] = [:]
    private var backgroundObserver: NSObjectProtocol?

    private func p2pParameters() -> NWParameters {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        return params
    }

    // MARK: - Lifecycle

    func setup(serviceType: String, deviceName: String) {
        queue.async {
            // Re-setup happens on every return to the search screen; shut the
            // previous run down completely first.
            self.stopListenerLocked()
            self.stopBrowserLocked()
            for name in Array(self.peers.keys) {
                self.teardownPeerLocked(name, notify: false)
            }
            self.discovered.removeAll()

            self.myName = deviceName
            self.bonjourType = "_\(serviceType)n._tcp"
            print("[NP2P] setup type=\(self.bonjourType) device=\(deviceName)")
        }
        if backgroundObserver == nil {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: nil
            ) { [weak self] _ in
                self?.queue.async { self?.enteredBackgroundLocked() }
            }
        }
    }

    private func enteredBackgroundLocked() {
        // Same behavior as the MPC engine: a backgrounded app drops its
        // connections; the app layer surfaces the disconnect.
        for name in Array(peers.keys) {
            teardownPeerLocked(name, notify: true)
        }
    }

    // MARK: - Advertise / Browse

    func startAdvertising() {
        queue.async {
            if self.listener != nil { return }
            do {
                let listener = try NWListener(using: self.p2pParameters())
                listener.service = NWListener.Service(
                    name: self.myName, type: self.bonjourType)
                listener.stateUpdateHandler = { state in
                    print("[NP2P] listener: \(state)")
                }
                listener.newConnectionHandler = { [weak self] conn in
                    self?.handleIncoming(conn)
                }
                listener.start(queue: self.queue)
                self.listener = listener
            } catch {
                print("[NP2P] listener error: \(error)")
            }
        }
    }

    func stopAdvertising() {
        queue.async { self.stopListenerLocked() }
    }

    private func stopListenerLocked() {
        listener?.cancel()
        listener = nil
    }

    func startBrowsing() {
        queue.async {
            if self.browser != nil { return }
            let browser = NWBrowser(
                for: .bonjour(type: self.bonjourType, domain: nil),
                using: self.p2pParameters())
            browser.stateUpdateHandler = { state in
                print("[NP2P] browser: \(state)")
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self = self else { return }
                self.discovered.removeAll()
                for result in results {
                    if case let NWEndpoint.service(name, _, _, _) = result.endpoint,
                       name != self.myName {
                        self.discovered[name] = result.endpoint
                    }
                }
                self.emitStateListLocked()
            }
            browser.start(queue: self.queue)
            self.browser = browser
        }
    }

    func stopBrowsing() {
        queue.async {
            self.stopBrowserLocked()
            self.discovered.removeAll()
            self.emitStateListLocked()
        }
    }

    private func stopBrowserLocked() {
        browser?.cancel()
        browser = nil
    }

    // MARK: - Connect / Disconnect

    func invite(_ name: String) {
        queue.async {
            guard let endpoint = self.discovered[name] else {
                print("[NP2P] invite: \(name) not in discovered list")
                return
            }
            if let existing = self.peers[name],
               existing.state != NetworkP2PManager.stateNotConnected {
                print("[NP2P] invite: \(name) already \(existing.state)")
                return
            }

            print("[NP2P] connecting to \(name)")
            let peer = Peer()
            self.peers[name] = peer
            self.emitStateListLocked()

            peer.command = self.openChannel(
                to: endpoint, peerName: name, tag: NetworkP2PManager.commandTag)
            peer.frame = self.openChannel(
                to: endpoint, peerName: name, tag: NetworkP2PManager.frameTag)

            // The OS keeps trying (waiting state) much longer than a user
            // would; bound the attempt ourselves.
            let timeout = DispatchWorkItem { [weak self] in
                guard let self = self,
                      let p = self.peers[name],
                      p.state == NetworkP2PManager.stateConnecting else { return }
                print("[NP2P] connect to \(name) timed out")
                self.teardownPeerLocked(name, notify: true)
            }
            peer.connectTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 30, execute: timeout)
        }
    }

    func disconnect(_ name: String) {
        queue.async { self.teardownPeerLocked(name, notify: true) }
    }

    // MARK: - Send

    func sendCommand(_ name: String, data: Data, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let channel = self.peers[name]?.command else {
                completion(false)
                return
            }
            channel.send(data, completion: completion)
        }
    }

    func sendFrame(_ name: String, data: Data, completion: @escaping (Bool) -> Void) {
        queue.async {
            guard let channel = self.peers[name]?.frame else {
                // Preview frames are droppable; the channel may simply not be
                // attached yet.
                completion(false)
                return
            }
            channel.send(data, completion: completion)
        }
    }

    // MARK: - Channel plumbing (all on `queue`)

    private func openChannel(to endpoint: NWEndpoint, peerName: String,
                             tag: UInt8) -> FramedChannel {
        let conn = NWConnection(to: endpoint, using: p2pParameters())
        let channel = FramedChannel(connection: conn, queue: queue)
        channel.onMessage = { [weak self] data in
            self?.deliverLocked(tag: tag, from: peerName, data: data)
        }
        channel.onReady = { [weak self] in
            guard let self = self else { return }
            var intro = Data([tag])
            intro.append(peerNameData(self.myName))
            channel.send(intro) { _ in }
            if tag == NetworkP2PManager.commandTag {
                self.markConnectedLocked(peerName)
            }
        }
        channel.onClosed = { [weak self] in
            self?.channelClosedLocked(peerName: peerName, tag: tag)
        }
        channel.start()
        return channel
    }

    private func handleIncoming(_ conn: NWConnection) {
        let channel = FramedChannel(connection: conn, queue: queue)
        // Identity is unknown until the intro message arrives.
        channel.onMessage = { [weak self] data in
            guard let self = self else { return }
            if channel.peerName == nil {
                guard data.count >= 2,
                      let name = String(data: data.dropFirst(), encoding: .utf8) else {
                    print("[NP2P] bad intro, dropping connection")
                    channel.cancel()
                    return
                }
                let tag = data[data.startIndex]
                channel.peerName = name
                channel.tag = tag
                self.registerIncomingLocked(channel: channel, name: name, tag: tag)
                return
            }
            if let name = channel.peerName, let tag = channel.tag {
                self.deliverLocked(tag: tag, from: name, data: data)
            }
        }
        channel.onClosed = { [weak self] in
            if let name = channel.peerName, let tag = channel.tag {
                self?.channelClosedLocked(peerName: name, tag: tag)
            }
        }
        channel.start()
    }

    private func registerIncomingLocked(channel: FramedChannel, name: String, tag: UInt8) {
        let peer = peers[name] ?? Peer()
        peers[name] = peer
        if tag == NetworkP2PManager.commandTag {
            peer.command = channel
            print("[NP2P] command channel from \(name)")
            markConnectedLocked(name)
        } else {
            peer.frame = channel
            print("[NP2P] frame channel from \(name)")
        }
    }

    private func markConnectedLocked(_ name: String) {
        guard let peer = peers[name] else { return }
        peer.connectTimeout?.cancel()
        peer.connectTimeout = nil
        if peer.state != NetworkP2PManager.stateConnected {
            peer.state = NetworkP2PManager.stateConnected
            print("[NP2P] connected to \(name)")
            emitStateListLocked()
        }
    }

    private func channelClosedLocked(peerName: String, tag: UInt8) {
        // Either channel dying takes the logical session with it — matches
        // the MPC engine, where the single session carried both.
        guard peers[peerName] != nil else { return }
        print("[NP2P] channel 0x\(String(tag, radix: 16)) to \(peerName) closed")
        teardownPeerLocked(peerName, notify: true)
    }

    private func teardownPeerLocked(_ name: String, notify: Bool) {
        guard let peer = peers.removeValue(forKey: name) else { return }
        peer.connectTimeout?.cancel()
        peer.command?.cancel()
        peer.frame?.cancel()
        if notify {
            // Emit with the peer forced visible at notConnected: the Dart
            // side detects disconnects by seeing the device in a
            // non-connected state, so it must appear in this event even if
            // browsing has already lost its record.
            emitStateListLocked(includingLost: name)
        }
    }

    // MARK: - Events to Dart

    private func emitStateListLocked(includingLost: String? = nil) {
        var names = Set(discovered.keys)
        names.formUnion(peers.keys)
        if let lost = includingLost { names.insert(lost) }

        let devices: [[String: Any]] = names.sorted().map { name in
            [
                "deviceId": name,
                "deviceName": name,
                "state": peers[name]?.state ?? NetworkP2PManager.stateNotConnected,
            ]
        }
        guard let json = try? JSONSerialization.data(withJSONObject: devices),
              let jsonString = String(data: json, encoding: .utf8) else { return }
        emit?(INVOKE_CHANGE_STATE_METHOD, jsonString)
    }

    private func deliverLocked(tag: UInt8, from name: String, data: Data) {
        let method = tag == NetworkP2PManager.commandTag
            ? INVOKE_COMMAND_BINARY_RECEIVE_METHOD
            : INVOKE_BINARY_RECEIVE_METHOD
        emit?(method, [
            "deviceId": name,
            "data": FlutterStandardTypedData(bytes: data),
        ] as [String: Any])
    }
}

private func peerNameData(_ name: String) -> Data {
    return name.data(using: .utf8) ?? Data()
}

/// One NWConnection carrying length-prefixed messages:
/// [UInt32 big-endian payload length][payload]. Restores atomic-message
/// semantics on top of the TCP byte stream.
@available(iOS 13.0, *)
class FramedChannel {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private var buffer = Data()
    private var closed = false

    // Set on incoming channels once the intro message identifies them.
    var peerName: String?
    var tag: UInt8?

    var onReady: (() -> Void)?
    var onMessage: ((Data) -> Void)?
    var onClosed: (() -> Void)?

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onReady?()
            case .failed(let error):
                print("[NP2P] connection failed: \(error)")
                self?.close()
            case .cancelled:
                self?.close()
            default:
                break
            }
        }
        receiveLoop()
        connection.start(queue: queue)
    }

    func cancel() {
        closed = true
        connection.cancel()
    }

    func send(_ payload: Data, completion: @escaping (Bool) -> Void) {
        var message = Data(capacity: payload.count + 4)
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(payload)
        // The completion fires when the OS has accepted the bytes — this is
        // the backpressure the Dart frame sender paces itself with.
        connection.send(content: message, completion: .contentProcessed { error in
            completion(error == nil)
        })
    }

    private func close() {
        if closed { return }
        closed = true
        connection.cancel()
        onClosed?()
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
                self.drainBuffer()
            }
            if isComplete || error != nil {
                self.close()
                return
            }
            if !self.closed {
                self.receiveLoop()
            }
        }
    }

    private func drainBuffer() {
        while true {
            guard buffer.count >= 4 else { return }
            let length = UInt32(bigEndian: buffer
                .subdata(in: buffer.startIndex..<(buffer.startIndex + 4))
                .withUnsafeBytes { $0.load(as: UInt32.self) })
            let total = 4 + Int(length)
            guard buffer.count >= total else { return }
            let payload = buffer.subdata(
                in: (buffer.startIndex + 4)..<(buffer.startIndex + total))
            buffer = buffer.subdata(
                in: (buffer.startIndex + total)..<buffer.endIndex)
            onMessage?(payload)
        }
    }
}
