import Flutter
import UIKit
import MultipeerConnectivity
import SwiftyJSON

let SERVICE_TYPE = "ioscreator-chat"
let INVOKE_CHANGE_STATE_METHOD = "invoke_change_state_method"
let INVOKE_MESSAGE_RECEIVE_METHOD = "invoke_message_receive_method"
let INVOKE_BINARY_RECEIVE_METHOD = "invoke_binary_receive_method"
let INVOKE_COMMAND_BINARY_RECEIVE_METHOD = "invoke_command_binary_receive_method"
let INVOKE_TRANSPORT_STATE_METHOD = "invoke_transport_state_method"

// First byte of every binary payload, routing it to the right logical channel.
// JSON messages always start with '{' (0x7B), so text and binary coexist on
// one MCSession.
//   0x02 — frame channel: preview frames, unreliable (stale frames drop)
//   0x03 — command channel: protobuf commands + full-quality photos, reliable
let BINARY_PAYLOAD_MARKER: UInt8 = 0x02
let COMMAND_BINARY_PAYLOAD_MARKER: UInt8 = 0x03

// On iOS 26, MultipeerConnectivity session establishment fails over
// peer-to-peer WiFi (AWDL) even though the radio path works — verified with a
// Network-framework probe. This flag routes the whole engine to
// NetworkP2PManager (NWListener/NWBrowser/NWConnection with includePeerToPeer)
// behind the SAME method-channel contract; flip to false to fall back to MPC.
let USE_NETWORK_P2P = true

enum MethodCall: String {
    case initNearbyService = "init_nearby_service"
    case startAdvertisingPeer = "start_advertising_peer"
    case startBrowsingForPeers = "start_browsing_for_peers"

    case stopAdvertisingPeer = "stop_advertising_peer"
    case stopBrowsingForPeers = "stop_browsing_for_peers"

    case invitePeer = "invite_peer"
    case disconnectPeer = "disconnect_peer"

    case sendMessage = "send_message"
    case sendBinary = "send_binary"
    case sendCommandBinary = "send_command_binary"
}

public class SwiftFlutterNearbyConnectionsPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_nearby_connections", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterNearbyConnectionsPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    var currentReceivedDevice: Device?
    
    let channel: FlutterMethodChannel
    
    struct DeviceJson {
        var deviceId:String
        var deviceName:String
        var state:Int
        
        func toStringAnyObject() -> [String: Any] {
            return [
                "deviceId": deviceId,
                "deviceName": deviceName,
                "state": state
            ]
        }
    }
    
    struct MessageJson {
        var deviceId:String
        var message:String
        
        func toStringAnyObject() -> [String: Any] {
            return [
                "deviceId": deviceId,
                "message": message
            ]
        }
    }
    
    @objc func stateChanged(){
        let devices = MPCManager.instance.devices.compactMap({return DeviceJson(deviceId: $0.peerID.displayName, deviceName: $0.peerID.displayName, state: $0.state.rawValue)})
        let arguments = JSON(devices.compactMap({return $0.toStringAnyObject()})).rawString()
        // MCSession delegates fire on a background queue; platform channel
        // calls off the main thread get dropped by newer Flutter engines —
        // a lost "connected" event here strands the app on the search screen.
        DispatchQueue.main.async {
            self.channel.invokeMethod(INVOKE_CHANGE_STATE_METHOD, arguments: arguments)
        }
    }
    
    @objc func messageReceived(notification: Notification) {
        do {
            guard let data = notification.userInfo?["data"] as? Data else { return }
            let marker = data.first
            if marker == BINARY_PAYLOAD_MARKER || marker == COMMAND_BINARY_PAYLOAD_MARKER {
                let method = marker == BINARY_PAYLOAD_MARKER
                    ? INVOKE_BINARY_RECEIVE_METHOD
                    : INVOKE_COMMAND_BINARY_RECEIVE_METHOD
                let deviceId = (notification.userInfo?["from"] as? MCPeerID)?.displayName ?? ""
                let payload = FlutterStandardTypedData(bytes: data.dropFirst())
                // MCSession delegates fire on a background queue; platform
                // channel calls must happen on the main thread.
                DispatchQueue.main.async {
                    self.channel.invokeMethod(method, arguments: [
                        "deviceId": deviceId,
                        "data": payload,
                    ] as [String: Any])
                }
                return
            }
            if let stringData = JSON(data).rawString() {
                let dict = convertToDictionary(text: stringData)
                DispatchQueue.main.async {
                    self.channel.invokeMethod(INVOKE_MESSAGE_RECEIVE_METHOD, arguments: dict)
                }
            }
        } catch let e {
            print(e.localizedDescription)
        }
    }
    
    func convertToDictionary(text: String) -> [String: Any]? {
        if let data = text.data(using: .utf8) {
            do {
                return try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            } catch {
                print(error.localizedDescription)
            }
        }
        return nil
    }
    
    public init(channel:FlutterMethodChannel) {
        self.channel = channel
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(stateChanged), name: MPCManager.Notifications.deviceDidChangeState, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(messageReceived), name: Device.messageReceivedNotification, object: nil)
        
        MPCManager.instance.deviceDidChange = {[weak self] in
            self?.stateChanged()
        }
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        if USE_NETWORK_P2P, #available(iOS 13.0, *) {
            handleNetworkP2P(call, result: result)
            return
        }
        switch MethodCall(rawValue: call.method) {
        case .initNearbyService:
            guard let data = call.arguments as? Dictionary<String, AnyObject> else {
                result(false)
                return
                
            }
            let serviceType:String = data["serviceType"] as? String ?? SERVICE_TYPE
            var deviceName:String = data["deviceName"] as? String ?? ""
            if (deviceName.isEmpty){
                deviceName =  UIDevice.current.name
            }
               
            MPCManager.instance.setup(serviceType: serviceType, deviceName: deviceName)
            currentReceivedDevice = Device(peerID: MPCManager.instance.localPeerID)
            result(true)
        case .startAdvertisingPeer:
            MPCManager.instance.startAdvertisingPeer()
            result(true)
        case .startBrowsingForPeers:
            MPCManager.instance.startBrowsingForPeers()
            result(true)
        case .stopAdvertisingPeer:
            MPCManager.instance.stopAdvertisingPeer()
            result(true)
        case .stopBrowsingForPeers:
            MPCManager.instance.stopBrowsingForPeers()
            result(true)
        case .invitePeer:
            guard let data = call.arguments as? Dictionary<String, AnyObject> else {
                result(false)
                return
                
            }
            guard let deviceId: String = data["deviceId"] as? String else {
                result(false)
                return
            }
            MPCManager.instance.invitePeer(deviceID: deviceId)
            result(true)

        case .disconnectPeer:
            guard let data = call.arguments as? Dictionary<String, AnyObject> else {
                result(false)
                return
                
            }
            let deviceId:String? = data["deviceId"] as? String ?? nil
            if (deviceId != nil) {
                MPCManager.instance.disconnectPeer(deviceID: deviceId!)
                result(true)
            } else {
                result(false)
            }
        case .sendMessage:
            guard let dict = call.arguments as? Dictionary<String, AnyObject> else {
                result(false)
                return
            }
            do {
                let jsonData = try JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted)
                if let device = MPCManager.instance.findDevice(for: dict["deviceId"] as! String) {
                    currentReceivedDevice = device
                    try device.send(data: jsonData)
                    result(true)
                    return
                }
            } catch let error as NSError {
                print(error)
            }
            result(false)
        case .sendBinary:
            guard let dict = call.arguments as? Dictionary<String, AnyObject>,
                  let deviceId = dict["deviceId"] as? String,
                  let typedData = dict["data"] as? FlutterStandardTypedData,
                  let device = MPCManager.instance.findDevice(for: deviceId) else {
                result(false)
                return
            }
            let reliable = dict["reliable"] as? Bool ?? false
            var payload = Data([BINARY_PAYLOAD_MARKER])
            payload.append(typedData.data)
            do {
                try device.send(data: payload, mode: reliable ? .reliable : .unreliable)
                result(true)
            } catch {
                // Unreliable sends have a size cap; retry the frame reliably
                // rather than dropping it with an error.
                do {
                    try device.send(data: payload, mode: .reliable)
                    result(true)
                } catch {
                    result(false)
                }
            }
        case .sendCommandBinary:
            guard let dict = call.arguments as? Dictionary<String, AnyObject>,
                  let deviceId = dict["deviceId"] as? String,
                  let typedData = dict["data"] as? FlutterStandardTypedData,
                  let device = MPCManager.instance.findDevice(for: deviceId) else {
                result(false)
                return
            }
            currentReceivedDevice = device
            var payload = Data([COMMAND_BINARY_PAYLOAD_MARKER])
            payload.append(typedData.data)
            do {
                // Commands (and full-quality photos) must arrive intact and in
                // order, so always reliable.
                try device.send(data: payload, mode: .reliable)
                result(true)
            } catch {
                result(false)
            }
        default:
            result(FlutterMethodNotImplemented)
            return
        }
    }

    /// The Network-framework engine behind the same method-channel contract
    /// the MPC engine served — the Dart side cannot tell them apart.
    @available(iOS 13.0, *)
    private func handleNetworkP2P(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let manager = NetworkP2PManager.instance
        switch MethodCall(rawValue: call.method) {
        case .initNearbyService:
            guard let data = call.arguments as? Dictionary<String, AnyObject> else {
                result(false)
                return
            }
            let serviceType: String = data["serviceType"] as? String ?? SERVICE_TYPE
            var deviceName: String = data["deviceName"] as? String ?? ""
            if deviceName.isEmpty {
                deviceName = UIDevice.current.name
            }
            manager.emit = { [weak self] method, arguments in
                // Platform-channel calls must happen on the main thread.
                DispatchQueue.main.async {
                    self?.channel.invokeMethod(method, arguments: arguments)
                }
            }
            manager.setup(serviceType: serviceType, deviceName: deviceName)
            result(true)
        case .startAdvertisingPeer:
            manager.startAdvertising()
            result(true)
        case .startBrowsingForPeers:
            manager.startBrowsing()
            result(true)
        case .stopAdvertisingPeer:
            manager.stopAdvertising()
            result(true)
        case .stopBrowsingForPeers:
            manager.stopBrowsing()
            result(true)
        case .invitePeer:
            guard let data = call.arguments as? Dictionary<String, AnyObject>,
                  let deviceId = data["deviceId"] as? String else {
                result(false)
                return
            }
            manager.invite(deviceId)
            result(true)
        case .disconnectPeer:
            guard let data = call.arguments as? Dictionary<String, AnyObject>,
                  let deviceId = data["deviceId"] as? String else {
                result(false)
                return
            }
            manager.disconnect(deviceId)
            result(true)
        case .sendMessage:
            // Legacy JSON-text path; unused since protocol v3 moved commands
            // to the binary channel.
            result(false)
        case .sendBinary:
            guard let dict = call.arguments as? Dictionary<String, AnyObject>,
                  let deviceId = dict["deviceId"] as? String,
                  let typedData = dict["data"] as? FlutterStandardTypedData else {
                result(false)
                return
            }
            manager.sendFrame(deviceId, data: typedData.data) { ok in
                DispatchQueue.main.async { result(ok) }
            }
        case .sendCommandBinary:
            guard let dict = call.arguments as? Dictionary<String, AnyObject>,
                  let deviceId = dict["deviceId"] as? String,
                  let typedData = dict["data"] as? FlutterStandardTypedData else {
                result(false)
                return
            }
            manager.sendCommand(deviceId, data: typedData.data) { ok in
                DispatchQueue.main.async { result(ok) }
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

}
