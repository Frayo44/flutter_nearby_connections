part of flutter_nearby_connections;

const _initNearbyService = 'init_nearby_service';
const _startAdvertisingPeer = 'start_advertising_peer';
const _stopAdvertisingPeer = 'stop_advertising_peer';
const _startBrowsingForPeers = 'start_browsing_for_peers';
const _stopBrowsingForPeers = 'stop_browsing_for_peers';
const _invitePeer = 'invite_peer';
const _disconnectPeer = 'disconnect_peer';
const _sendMessage = 'send_message';
const _sendBinary = 'send_binary';
const _sendCommandBinary = 'send_command_binary';
const _invokeChangeStateMethod = "invoke_change_state_method";
const _invokeMessageReceiveMethod = "invoke_message_receive_method";
const _invokeBinaryReceiveMethod = "invoke_binary_receive_method";
const _invokeCommandBinaryReceiveMethod = "invoke_command_binary_receive_method";
const _invokeNearbyRunning = "nearby_running";
const _invokeTransportStateMethod = "invoke_transport_state_method";

/// [StateChangedCallback] is used to call back an object under List<Device>.
/// [StateChangedCallback] will call when you register in [stateChangedSubscription]
typedef StateChangedCallback = Function(List<Device> arguments);

/// [DataReceivedCallback] is used to call back an object under List<Device>.
/// [DataReceivedCallback] will call when you register in [dataReceivedSubscription]
typedef DataReceivedCallback = Function(dynamic data);

/// [BinaryReceivedCallback] fires for raw binary payloads sent with
/// [NearbyService.sendBinary] or [NearbyService.sendCommandBinary]. iOS only.
typedef BinaryReceivedCallback = Function(String deviceId, Uint8List data);

/// [TransportStateCallback] fires when the underlying transport engine
/// changes state ([component] is "listener" or "browser"; [state] is
/// "ready", "waiting" or "failed"; [error] is the platform error text, empty
/// for "ready"). A browser entering "waiting" is how iOS reports a denied
/// Local Network permission. iOS only.
typedef TransportStateCallback = Function(
    String component, String state, String error);

class _BinaryMessage {
  final String deviceId;
  final Uint8List data;

  _BinaryMessage(this.deviceId, this.data);
}

class NearbyService {
  static const MethodChannel _channel =
      const MethodChannel('flutter_nearby_connections');

  final _stateChangedController = StreamController<List<Device>>.broadcast();

  Stream<List<Device>> get _stateChangedStream =>
      _stateChangedController.stream;

  final _dataReceivedController = StreamController<dynamic>.broadcast();

  Stream<dynamic> get _dataReceivedStream => _dataReceivedController.stream;

  final _binaryReceivedController =
      StreamController<_BinaryMessage>.broadcast();

  Stream<_BinaryMessage> get _binaryReceivedStream =>
      _binaryReceivedController.stream;

  final _commandBinaryReceivedController =
      StreamController<_BinaryMessage>.broadcast();

  Stream<_BinaryMessage> get _commandBinaryReceivedStream =>
      _commandBinaryReceivedController.stream;

  final _transportStateController =
      StreamController<Map<String, String>>.broadcast();

  Stream<Map<String, String>> get _transportStateStream =>
      _transportStateController.stream;
  String? _deviceName;

  /// The class [NearbyService] supports the discovery of services provided by
  /// nearby devices and supports communicating with those services through
  /// message-based data, streaming data, and resources (such as files).
  /// In iOS, the framework uses infrastructure Wi-Fi networks, peer-to-peer Wi-Fi,
  /// and Bluetooth personal area networks for the underlying transport.
  /// param [serviceType] max length 15 character, need to be defined in Info.plist
  ///
  /// <key>NSBonjourServices</key>
  /// 	<array>
  /// 		<string>_[serviceType]._tcp</string>
  /// 	</array>
  ///
  /// param [deviceId] is unique, you should use the UDID for [deviceId]
  /// param [strategy] Nearby Connections supports different Strategies for advertising and discovery. The best Strategy to use depends on the use case. only support android OS
  Future init(
      {required String serviceType,
      required Strategy strategy,
      String? deviceName,
      required Function callback}) async {
    _deviceName = deviceName;
    assert(serviceType.length <= 15 &&
        //serviceType != null &&
        serviceType.isNotEmpty);

    _channel.setMethodCallHandler((handler) async {
      // Binary payloads arrive at frame-stream rates (and command binaries
      // carry full photos); logging them would dump tens of KB per message.
      if (handler.method != _invokeBinaryReceiveMethod &&
          handler.method != _invokeCommandBinaryReceiveMethod) {
        debugPrint(
            "method: ${handler.method} | arguments: ${handler.arguments}");
      }
      switch (handler.method) {
        case _invokeChangeStateMethod:
          List<Device> devices = jsonDecode(handler.arguments)
              .map<Device>((dynamic device) => Device.fromJson(device))
              .toList();
          _stateChangedController.add(devices);
          break;
        case _invokeMessageReceiveMethod:
          _dataReceivedController.add(handler.arguments);
          debugPrint(
              "_invokeMessageReceiveMethod | arguments: ${handler.arguments}");
          break;
        case _invokeBinaryReceiveMethod:
          final args = handler.arguments as Map;
          _binaryReceivedController.add(_BinaryMessage(
              args["deviceId"] as String, args["data"] as Uint8List));
          break;
        case _invokeCommandBinaryReceiveMethod:
          final args = handler.arguments as Map;
          _commandBinaryReceivedController.add(_BinaryMessage(
              args["deviceId"] as String, args["data"] as Uint8List));
          break;
        case _invokeNearbyRunning:
          await Future.delayed(Duration(seconds: 1));
          callback(handler.arguments as bool);
          break;
        case _invokeTransportStateMethod:
          final args = handler.arguments as Map;
          _transportStateController.add({
            "component": args["component"] as String? ?? "",
            "state": args["state"] as String? ?? "",
            "error": args["error"] as String? ?? "",
          });
          break;
      }
    });

    int strategyValue = 0;
    switch (strategy) {
      case Strategy.P2P_CLUSTER:
        strategyValue = 0;
        break;
      case Strategy.P2P_STAR:
        strategyValue = 1;
        break;
      case Strategy.P2P_POINT_TO_POINT:
        strategyValue = 2;
        break;
      case Strategy.Wi_Fi_P2P:
        strategyValue = 0;
        break;
    }

    _channel.invokeMethod(
      _initNearbyService,
      <String, dynamic>{
        'deviceName': deviceName ?? "",
        'serviceType': serviceType,
        'strategy': strategyValue,
      },
    );
    if (Platform.isIOS) {
      await Future.delayed(Duration(seconds: 1));
      callback(true);
    }
  }

  /// Begins advertising the service provided by a local peer.
  /// The [startAdvertisingPeer] publishes an advertisement for a specific service
  /// that your app provides through the flutter_nearby_connections plugin and
  /// notifies its delegate about invitations from nearby peers.
  FutureOr<dynamic> startAdvertisingPeer() async {
    await _channel.invokeMethod(_startAdvertisingPeer);
  }

  /// Starts browsing for peers.
  /// Searches (by [serviceType]) for services offered by nearby devices using
  /// infrastructure Wi-Fi, peer-to-peer Wi-Fi, and Bluetooth or Ethernet, and
  /// provides the ability to easily invite those [Device] to a earby connections
  /// session [SessionState].
  FutureOr<dynamic> startBrowsingForPeers() async {
    await _channel.invokeMethod(_startBrowsingForPeers);
  }

  /// Stops advertising this peer device for connection.
  FutureOr<dynamic> stopAdvertisingPeer() async {
    await _channel.invokeMethod(_stopAdvertisingPeer);
  }

  /// Stops browsing for peers.
  FutureOr<dynamic> stopBrowsingForPeers() async {
    await _channel.invokeMethod(_stopBrowsingForPeers);
  }

  /// Invites a discovered peer to join a nearby connections session.
  /// the [deviceID] is current Device
  FutureOr<dynamic> invitePeer(
      {required String deviceID, @required String? deviceName}) async {
    await _channel.invokeMethod(
      _invitePeer,
      <String, dynamic>{
        'deviceId': deviceID,
        'deviceName': deviceName,
      },
    );
  }

  /// Disconnects the local peer from the session.
  /// the [deviceID] is current Device
  FutureOr<dynamic> disconnectPeer({required String? deviceID}) async {
    await _channel.invokeMethod(_disconnectPeer, <String, dynamic>{
      'deviceId': deviceID,
    });
  }

  /// Sends a message encapsulated in a Data instance to nearby peers.
  FutureOr<dynamic> sendMessage(String deviceID, String message) async {
    await _channel.invokeMethod(_sendMessage, <String, dynamic>{
      'deviceId': deviceID,
      if (_deviceName != null) 'senderDeviceId': _deviceName,
      'message': message,
    });
  }

  /// Sends raw bytes to a peer with no JSON/string round-trip — suited for
  /// high-frequency payloads such as preview frames. With [reliable] false the
  /// message may be dropped under load instead of queueing (MPC .unreliable),
  /// which keeps a frame stream live instead of lagging. iOS only.
  FutureOr<dynamic> sendBinary(String deviceID, Uint8List data,
      {bool reliable = false}) async {
    await _channel.invokeMethod(_sendBinary, <String, dynamic>{
      'deviceId': deviceID,
      'data': data,
      'reliable': reliable,
    });
  }

  /// Sends raw bytes over the command channel: always reliable (ordered,
  /// guaranteed) with no JSON/string round-trip. Suited for control messages
  /// and larger one-off payloads such as full-quality photos. Delivered to
  /// [commandBinaryReceivedSubscription], separate from [sendBinary]'s frame
  /// channel. iOS only.
  FutureOr<dynamic> sendCommandBinary(String deviceID, Uint8List data) async {
    await _channel.invokeMethod(_sendCommandBinary, <String, dynamic>{
      'deviceId': deviceID,
      'data': data,
    });
  }

  /// [stateChangedSubscription] helps you listen to the changes of peers with
  /// the circumstances: find a new peer, a peer is invited, a peer is disconnected,
  /// a peer is invited to connect by another peer, or 2 peers are connected.
  /// [stateChangedSubscription] will return you a list of [Device].
  /// see [StateChangedCallback]
  StreamSubscription stateChangedSubscription(
      {required StateChangedCallback callback}) =>
      _stateChangedStream.listen(callback);

  /// The [dataReceivedSubscription] helps you listen when a peer sends you
  /// text messages. and it returns you a object [Data].
  /// It returns a [StreamSubscription] so you can cancel listening at any time.
  /// see [DataReceivedCallback]
  StreamSubscription dataReceivedSubscription(
      {required DataReceivedCallback callback}) =>
      _dataReceivedStream.listen(callback);

  /// Listens for raw binary payloads sent by a peer via [sendBinary]
  /// (the frame channel).
  /// see [BinaryReceivedCallback]
  StreamSubscription binaryReceivedSubscription(
      {required BinaryReceivedCallback callback}) =>
      _binaryReceivedStream.listen((m) => callback(m.deviceId, m.data));

  /// Listens for raw binary payloads sent by a peer via [sendCommandBinary]
  /// (the command channel).
  /// see [BinaryReceivedCallback]
  StreamSubscription commandBinaryReceivedSubscription(
      {required BinaryReceivedCallback callback}) =>
      _commandBinaryReceivedStream.listen((m) => callback(m.deviceId, m.data));

  /// Listens for state changes of the underlying transport engine
  /// (listener/browser ready, waiting or failed). A browser entering
  /// "waiting" is how iOS reports a denied Local Network permission,
  /// including a revocation mid-session. iOS only.
  /// see [TransportStateCallback]
  StreamSubscription transportStateSubscription(
      {required TransportStateCallback callback}) =>
      _transportStateStream.listen(
          (m) => callback(m["component"]!, m["state"]!, m["error"]!));
}
