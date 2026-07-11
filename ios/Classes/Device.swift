import Foundation
import MultipeerConnectivity
import SwiftyJSON

class Device: NSObject {
    let peerID: MCPeerID
    var session: MCSession?
    var state = MCSessionState.notConnected
    var lastMessageReceived: Message?
    
    static let messageReceivedNotification = Notification.Name("DeviceDidReceiveMessage")
    
    init(peerID: MCPeerID) {
        self.peerID = peerID
        super.init()
    }
    
    func createSession() {
        if self.session != nil { return }
        // .required makes the session negotiate DTLS during setup, which on
        // recent iOS reliably fails (or crawls) over peer-to-peer WiFi/AWDL —
        // i.e. whenever the phones don't share a WiFi network. .none trades
        // link encryption for a connection that actually establishes there.
        // Both peers must use the same preference: .none and .required
        // sessions refuse each other.
        self.session = MCSession(peer: MPCManager.instance.localPeerID, securityIdentity: nil, encryptionPreference: .none)
        self.session?.delegate = self
    }
    
    func disconnect() {
        self.session?.disconnect()
        self.session = nil
        NotificationCenter.default.post(name: MPCManager.Notifications.deviceDidChangeState, object: self)
    }
    
    func invite(with browser: MCNearbyServiceBrowser) {
        if (self.state == MCSessionState.notConnected) {
            // A session left over from a failed/timed-out attempt is dead
            // weight — inviting into it silently goes nowhere. Start clean.
            if self.session != nil {
                self.session?.delegate = nil
                self.session?.disconnect()
                self.session = nil
            }
            self.createSession()
            if let session = session {
                // Peer-to-peer WiFi (no shared network) needs AWDL to sync up,
                // which can take well over 10s; give the OS a real window.
                print("[MPC] inviting \(self.peerID.displayName) (timeout 30)")
                browser.invitePeer(self.peerID, to: session, withContext: nil, timeout: 30)
            }
        }
    }
}

extension Device: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        // 0=notConnected 1=connecting 2=connected. connecting→notConnected on
        // the inviter without the invitee ever logging "invitation received"
        // means the invite was never delivered (ghost peer / AWDL down).
        print("[MPC] session \(peerID.displayName) -> \(state.rawValue)")
        self.state = state
        NotificationCenter.default.post(name: MPCManager.Notifications.deviceDidChangeState, object: nil)
    }
    
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        NotificationCenter.default.post(name: Device.messageReceivedNotification, object: nil, userInfo: ["from": peerID, "data": data])
    }
    
    public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) { }
    
    public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) { }
    
    public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) { }
    
}
