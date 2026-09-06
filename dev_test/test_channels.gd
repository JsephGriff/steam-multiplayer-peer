extends Node

const PORT := 24575

var peer: SteamMultiplayerPeer
var mode := "host"
var normal_packets: Array = []
var channel_packets: Array = []
var host_replied := false
var client_peer_id := 0
var passed := false
var failed := false

func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			mode = arg.get_slice("=", 1)
	if not Steam.isSteamRunning() or not Steam.loggedOn():
		_fail("Steam is not running or logged on")
		return
	print("mode=%s steam_id=%d" % [mode, Steam.getSteamID()])

	if mode == "client":
		await get_tree().create_timer(2.0).timeout
	peer = SteamMultiplayerPeer.new()
	if mode == "host":
		var err: Error = peer.create_host(PORT)
		if err != OK:
			_fail("create_host failed: %d" % err)
			return
	elif mode == "host_ip":
		var err: Error = peer.create_host_ip(PORT)
		if err != OK:
			_fail("create_host_ip failed: %d" % err)
			return
	elif mode == "client_ip":
		var err: Error = peer.create_client_ip("127.0.0.1", PORT)
		if err != OK:
			_fail("create_client_ip failed: %d" % err)
			return
	else:
		var err: Error = peer.create_client(Steam.getSteamID(), PORT)
		if err != OK:
			_fail("create_client failed: %d" % err)
			return
	peer.network_connection_status_changed.connect(func(handle: int, info: Dictionary, old_state: int) -> void:
		print("%s status changed: old=%d new=%s" % [mode, old_state, info.get("connection_state", info)]))
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)

	get_tree().create_timer(45.0).timeout.connect(func() -> void:
		if not passed and not failed:
			_fail("timeout (mode=%s) normal=%s channel=%s" % [mode, normal_packets, channel_packets])
	)

func _process(_delta: float) -> void:
	Steam.run_callbacks()
	if peer == null or failed:
		return
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var packet := {
			"channel": peer.get_packet_channel(),
			"peer": peer.get_packet_peer(),
			"data": peer.get_packet().get_string_from_utf8(),
		}
		normal_packets.append(packet)
		print("%s normal packet: %s" % [mode, packet])
	while peer.get_channel_packet_count() > 0:
		var packet: Dictionary = peer.get_channel_packet()
		packet["data"] = packet["data"].get_string_from_utf8()
		channel_packets.append(packet)
		print("%s channel packet: %s" % [mode, packet])
	if mode.begins_with("host"):
		_host_flow()
	else:
		_client_flow()

func _host_flow() -> void:
	if passed:
		return
	if not client_peer_id:
		var ping := normal_packets.filter(func(p): return p["data"] == "ch0-ping")
		if ping.is_empty():
			return
		client_peer_id = ping[0]["peer"]
	if not host_replied:
		host_replied = true
		peer.set_target_peer(client_peer_id)
		peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
		peer.set_transfer_channel(3)
		var err: Error = peer.put_packet("ch3-reply".to_utf8_buffer())
		print("host sent ch3 reply to %d: %d" % [client_peer_id, err])
	var seq: Array = channel_packets.filter(func(p): return p["channel"] == 1)
	var saw_unreliable := channel_packets.any(func(p): return p["channel"] == 2 and p["data"] == "ch2-unreliable")
	if seq.size() == 5 and saw_unreliable:
		var ordered := true
		for i in range(5):
			if seq[i]["data"] != "ch1-seq-%d" % i:
				ordered = false
		if ordered:
			_pass("HOST ALL TESTS PASSED")

func _on_peer_connected(id: int) -> void:
	print("peer_connected: %d" % id)
	if mode.begins_with("client"):
		_client_send()

func _on_peer_disconnected(id: int) -> void:
	print("peer_disconnected: %d" % id)
	if not passed and not failed:
		_fail("peer %d disconnected before tests completed" % id)

func _client_send() -> void:
	peer.set_target_peer(1)
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_RELIABLE)
	peer.set_transfer_channel(0)
	print("send ch0: %d" % peer.put_packet("ch0-ping".to_utf8_buffer()))
	peer.set_transfer_channel(1)
	for i in range(5):
		print("send ch1 #%d: %d" % [i, peer.put_packet(("ch1-seq-%d" % i).to_utf8_buffer())])
	peer.set_transfer_mode(MultiplayerPeer.TRANSFER_MODE_UNRELIABLE)
	peer.set_transfer_channel(2)
	print("send ch2: %d" % peer.put_packet("ch2-unreliable".to_utf8_buffer()))
	peer.set_transfer_channel(0)

func _client_flow() -> void:
	if not passed and channel_packets.any(func(p): return p["channel"] == 3 and p["data"] == "ch3-reply"):
		_pass("CLIENT ALL TESTS PASSED")

func _pass(message: String) -> void:
	if passed or failed:
		return
	passed = true
	print(message)
	if mode.begins_with("host"):
		await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)

func _fail(message: String) -> void:
	if failed or passed:
		return
	failed = true
	print("TEST FAILED: " + message)
	get_tree().quit(1)
