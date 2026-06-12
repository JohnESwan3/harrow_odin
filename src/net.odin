package main

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:net"

// UDP listen-server networking ("P2P host"). One player hosts; others join
// with the server name (LAN discovery) or direct IP, plus a password.
//
//   client --DISCOVER--> broadcast      host --INFO--> client
//   client --JOIN(pw,name)--> host      host --ACCEPT(id)/DENY-->
//   client --STATE--> host (30 Hz)      host --SNAPSHOT--> all (20 Hz)
//   shooter --SHOT/HIT--> host --> relayed

NET_PORT :: 27499
NET_MAGIC :: u32(0x564D5031) // "VMP1"
NET_PROTOCOL :: u8(2)
NAME_LEN :: 16
SERVER_NAME_LEN :: 24
NET_TIMEOUT :: 6.0

Msg_Kind :: enum u8 {
	Discover_Req,
	Discover_Resp,
	Join_Req,
	Join_Accept,
	Join_Deny,
	State,
	Snapshot,
	Shot,
	Hit,
	Leave,
	Ping,
	Pong,
	Voxel, // world edit op
	Voxel_Batch, // edit history for late joiners
}

Voxel_Op :: struct #packed {
	pos:   [3]f32,
	r:     f32,
	power: f32,
}

Msg_Voxel :: struct #packed {
	header: Net_Header,
	sender: u8,
	op:     Voxel_Op,
}

VOXEL_BATCH_MAX :: 30

Msg_Voxel_Batch :: struct #packed {
	header: Net_Header,
	count:  u8,
	ops:    [VOXEL_BATCH_MAX]Voxel_Op,
}

Net_Header :: struct #packed {
	magic: u32,
	kind:  Msg_Kind,
}

Msg_Discover_Resp :: struct #packed {
	header:      Net_Header,
	server_name: [SERVER_NAME_LEN]u8,
	players:     u8,
	max_players: u8,
	protocol:    u8,
}

Msg_Join_Req :: struct #packed {
	header:    Net_Header,
	protocol:  u8,
	pass_hash: u64,
	name:      [NAME_LEN]u8,
	color:     u8,
}

Join_Deny_Reason :: enum u8 {
	Bad_Password,
	Server_Full,
	Bad_Protocol,
}

Msg_Join_Accept :: struct #packed {
	header: Net_Header,
	id:     u8,
}

Msg_Join_Deny :: struct #packed {
	header: Net_Header,
	reason: Join_Deny_Reason,
}

Net_Player_State :: struct #packed {
	pos:    [3]f32,
	vel:    [3]f32,
	yaw:    f32,
	pitch:  f32,
	weapon: u8,
	flags:  u8, // bit per Player_Flags
	health: f32,
	shield: f32,
}

Msg_State :: struct #packed {
	header: Net_Header,
	id:     u8,
	state:  Net_Player_State,
}

Msg_Snapshot :: struct #packed {
	header: Net_Header,
	active: u8, // bitmask of live slots
	states: [MAX_PLAYERS]Net_Player_State,
	names:  [MAX_PLAYERS][NAME_LEN]u8,
	colors: [MAX_PLAYERS]u8,
}

Msg_Shot :: struct #packed {
	header:  Net_Header,
	shooter: u8,
	weapon:  u8,
	origin:  [3]f32,
	dir:     [3]f32,
	hit_t:   f32,
}

Msg_Hit :: struct #packed {
	header: Net_Header,
	target: u8,
	damage: f32,
}

Msg_Simple :: struct #packed {
	header: Net_Header,
	id:     u8,
}

Net_Role :: enum {
	None,
	Host,
	Client,
}

Server_Entry :: struct {
	name:    string,
	ep:      net.Endpoint,
	players: int,
	max:     int,
	age:     f32,
}

Net_Client_Slot :: struct {
	used:      bool,
	ep:        net.Endpoint,
	last_seen: f32,
}

Net :: struct {
	role:         Net_Role,
	sock:         net.UDP_Socket,
	sock_ok:      bool,
	server_name:  [SERVER_NAME_LEN]u8,
	pass_hash:    u64,
	clients:      [MAX_PLAYERS]Net_Client_Slot, // host: by player id
	server_ep:    net.Endpoint, // client: host address
	state_acc:    f32,
	snap_acc:     f32,
	ping_acc:     f32,
	ping_sent_at: f32,
	ping_ms:      int,
	last_snap:    f32, // client: seconds since last snapshot

	// join flow (client)
	joining:      bool,
	join_acc:     f32,
	join_timeout: f32,
	join_req:     Msg_Join_Req,

	// discovery (client browser)
	discover_acc: f32,
	servers:      [dynamic]Server_Entry,
}

nett: Net

pass_hash_of :: proc(password: string) -> u64 {
	return hash.fnv64a(transmute([]u8)password)
}

fixed_str :: proc(buf: []u8) -> string {
	n := 0
	for n < len(buf) && buf[n] != 0 do n += 1
	return string(buf[:n])
}

set_fixed :: proc(buf: []u8, s: string) {
	mem.zero_slice(buf)
	copy(buf, s)
}

net_send :: proc(ep: net.Endpoint, msg: ^$T) {
	if !nett.sock_ok do return
	bytes := mem.ptr_to_bytes(msg)
	net.send_udp(nett.sock, bytes, ep)
}

net_open_socket :: proc(port: int) -> bool {
	sock, err := net.make_bound_udp_socket(net.IP4_Any, port)
	if err != nil {
		game_status(fmt.tprintf("NETWORK ERROR: %v", err))
		return false
	}
	net.set_blocking(sock, false)
	net.set_option(sock, .Broadcast, true)
	nett.sock = sock
	nett.sock_ok = true
	return true
}

net_stop :: proc() {
	if nett.sock_ok {
		if nett.role == .Client {
			leave := Msg_Simple {
				header = {NET_MAGIC, .Leave},
				id     = u8(game.local_id),
			}
			net_send(nett.server_ep, &leave)
		}
		net.close(nett.sock)
	}
	nett.sock_ok = false
	nett.role = .None
	nett.joining = false
	for &c in nett.clients do c.used = false
	for s in nett.servers do delete(s.name)
	clear(&nett.servers)
}

net_host_start :: proc(server_name, password: string) -> bool {
	net_stop()
	if !net_open_socket(NET_PORT) do return false
	nett.role = .Host
	set_fixed(nett.server_name[:], server_name)
	nett.pass_hash = pass_hash_of(password)
	return true
}

// open an ephemeral socket used for both discovery and play (client)
net_client_start :: proc() -> bool {
	net_stop()
	if !net_open_socket(0) do return false
	nett.role = .Client
	return true
}

net_client_join :: proc(ep: net.Endpoint, password, player_name: string) {
	nett.server_ep = ep
	nett.joining = true
	nett.join_acc = 0
	nett.join_timeout = 5.0
	nett.join_req = {
		header    = {NET_MAGIC, .Join_Req},
		protocol  = NET_PROTOCOL,
		pass_hash = pass_hash_of(password),
		color     = u8(game.settings.color_idx),
	}
	set_fixed(nett.join_req.name[:], player_name)
	net_send(ep, &nett.join_req)
}

net_broadcast_discover :: proc() {
	req := Net_Header{NET_MAGIC, .Discover_Req}
	bcast := net.Endpoint {
		address = net.IP4_Address{255, 255, 255, 255},
		port    = NET_PORT,
	}
	net_send(bcast, &req)
}

player_to_net :: proc(p: ^Player, firing: bool) -> Net_Player_State {
	flags: u8
	if firing do flags |= 1 << u8(Player_Flags.Firing)
	if p.crouching do flags |= 1 << u8(Player_Flags.Crouching)
	if p.alive do flags |= 1 << u8(Player_Flags.Alive)
	if p.ads do flags |= 1 << u8(Player_Flags.ADS)
	if p.sprinting do flags |= 1 << u8(Player_Flags.Sprinting)
	return {
		pos = p.pos,
		vel = p.vel,
		yaw = p.yaw,
		pitch = p.pitch,
		weapon = u8(p.weapon),
		flags = flags,
		health = p.health,
		shield = p.shield,
	}
}

net_apply_state :: proc(id: int, s: Net_Player_State) {
	if id == game.local_id do return
	p := &game.players[id]
	was_active := game.active[id]
	game.active[id] = true
	p.net_pos = s.pos
	p.net_vel = s.vel
	p.net_yaw = s.yaw
	p.net_pitch = s.pitch
	p.net_age = 0
	p.weapon = Weapon_Kind(min(s.weapon, u8(max(Weapon_Kind))))
	p.crouching = (s.flags & (1 << u8(Player_Flags.Crouching))) != 0
	p.alive = (s.flags & (1 << u8(Player_Flags.Alive))) != 0
	p.ads = (s.flags & (1 << u8(Player_Flags.ADS))) != 0
	p.sprinting = (s.flags & (1 << u8(Player_Flags.Sprinting))) != 0
	if (s.flags & (1 << u8(Player_Flags.Firing))) != 0 do p.firing_vis = 0.1
	p.health = s.health
	p.shield = s.shield
	if !was_active {
		p.pos = s.pos
		p.yaw = s.yaw
	}
}

msg_as :: proc($T: typeid, data: []u8) -> (^T, bool) {
	if len(data) < size_of(T) do return nil, false
	return (^T)(raw_data(data)), true
}

net_update :: proc(dt: f32) {
	if !nett.sock_ok do return

	// receive everything pending
	buf: [2048]u8
	for {
		n, ep, err := net.recv_udp(nett.sock, buf[:])
		if err != nil || n <= 0 do break
		net_handle(buf[:n], ep)
	}

	switch nett.role {
	case .None:
	case .Host:
		net_update_host(dt)
	case .Client:
		net_update_client(dt)
	}

	// expire stale discovery entries
	for i := len(nett.servers) - 1; i >= 0; i -= 1 {
		nett.servers[i].age += dt
		if nett.servers[i].age > 5 {
			delete(nett.servers[i].name)
			unordered_remove(&nett.servers, i)
		}
	}
}

net_update_host :: proc(dt: f32) {
	local := &game.players[game.local_id]

	// timeouts
	for &c, id in nett.clients {
		if !c.used do continue
		c.last_seen += dt
		if c.last_seen > NET_TIMEOUT {
			c.used = false
			game.active[id] = false
			game_status(fmt.tprintf("%s TIMED OUT", fixed_str(game.names[id][:])))
		}
	}

	// snapshot broadcast at 20 Hz
	nett.snap_acc += dt
	if nett.snap_acc >= 0.05 {
		nett.snap_acc = 0
		snap := Msg_Snapshot {
			header = {NET_MAGIC, .Snapshot},
		}
		for id in 0 ..< MAX_PLAYERS {
			if !game.active[id] do continue
			snap.active |= 1 << u8(id)
			p := &game.players[id]
			firing := id == game.local_id ? game.fired_this_window : p.firing_vis > 0
			snap.states[id] = player_to_net(p, firing)
			snap.names[id] = game.names[id]
			snap.colors[id] = game.colors[id]
		}
		game.fired_this_window = false
		for &c in nett.clients {
			if c.used do net_send(c.ep, &snap)
		}
	}
	_ = local
}

net_update_client :: proc(dt: f32) {
	if nett.joining {
		nett.join_acc += dt
		nett.join_timeout -= dt
		if nett.join_acc > 0.5 {
			nett.join_acc = 0
			net_send(nett.server_ep, &nett.join_req)
		}
		if nett.join_timeout <= 0 {
			nett.joining = false
			game_status("CONNECTION FAILED: NO RESPONSE")
		}
		return
	}
	if game.screen != .In_Game do return

	nett.last_snap += dt
	if nett.last_snap > NET_TIMEOUT {
		game_leave_session("CONNECTION LOST")
		return
	}

	// our state at 30 Hz
	nett.state_acc += dt
	if nett.state_acc >= 1.0 / 30.0 {
		nett.state_acc = 0
		msg := Msg_State {
			header = {NET_MAGIC, .State},
			id     = u8(game.local_id),
			state  = player_to_net(&game.players[game.local_id], game.fired_this_window),
		}
		game.fired_this_window = false
		net_send(nett.server_ep, &msg)
	}

	// ping at 1 Hz
	nett.ping_acc += dt
	if nett.ping_acc >= 1.0 {
		nett.ping_acc = 0
		nett.ping_sent_at = game.time
		ping := Msg_Simple {
			header = {NET_MAGIC, .Ping},
			id     = u8(game.local_id),
		}
		net_send(nett.server_ep, &ping)
	}
}

net_handle :: proc(data: []u8, from: net.Endpoint) {
	header, ok := msg_as(Net_Header, data)
	if !ok || header.magic != NET_MAGIC do return

	switch header.kind {
	case .Discover_Req:
		if nett.role != .Host do return
		resp := Msg_Discover_Resp {
			header      = {NET_MAGIC, .Discover_Resp},
			server_name = nett.server_name,
			players     = u8(game_player_count()),
			max_players = MAX_PLAYERS,
			protocol    = NET_PROTOCOL,
		}
		net_send(from, &resp)

	case .Discover_Resp:
		if nett.role != .Client do return
		msg, mok := msg_as(Msg_Discover_Resp, data)
		if !mok do return
		name := fixed_str(msg.server_name[:])
		for &s in nett.servers {
			if s.ep == from {
				s.age = 0
				s.players = int(msg.players)
				return
			}
		}
		append(
			&nett.servers,
			Server_Entry {
				name = clone_string(name),
				ep = from,
				players = int(msg.players),
				max = int(msg.max_players),
			},
		)

	case .Join_Req:
		if nett.role != .Host do return
		msg, mok := msg_as(Msg_Join_Req, data)
		if !mok do return
		// already joined? re-send accept (lost packet)
		for c, id in nett.clients {
			if c.used && c.ep == from {
				acc := Msg_Join_Accept {
					header = {NET_MAGIC, .Join_Accept},
					id     = u8(id),
				}
				net_send(from, &acc)
				return
			}
		}
		deny_reason: Join_Deny_Reason
		deny := false
		slot := -1
		if msg.protocol != NET_PROTOCOL {
			deny = true
			deny_reason = .Bad_Protocol
		} else if msg.pass_hash != nett.pass_hash {
			deny = true
			deny_reason = .Bad_Password
		} else {
			for id in 0 ..< MAX_PLAYERS {
				if id != game.local_id && !nett.clients[id].used {
					slot = id
					break
				}
			}
			if slot < 0 {
				deny = true
				deny_reason = .Server_Full
			}
		}
		if deny {
			dmsg := Msg_Join_Deny {
				header = {NET_MAGIC, .Join_Deny},
				reason = deny_reason,
			}
			net_send(from, &dmsg)
			return
		}
		nett.clients[slot] = {
			used      = true,
			ep        = from,
			last_seen = 0,
		}
		game.active[slot] = true
		game.names[slot] = msg.name
		game.colors[slot] = msg.color
		player_spawn(&game.players[slot], slot)
		game.players[slot].net_pos = game.players[slot].pos
		acc := Msg_Join_Accept {
			header = {NET_MAGIC, .Join_Accept},
			id     = u8(slot),
		}
		net_send(from, &acc)
		// stream world edit history so the joiner's terrain matches
		batch := Msg_Voxel_Batch {
			header = {NET_MAGIC, .Voxel_Batch},
		}
		for op in voxw.op_log {
			batch.ops[batch.count] = op
			batch.count += 1
			if int(batch.count) == VOXEL_BATCH_MAX {
				net_send(from, &batch)
				batch.count = 0
			}
		}
		if batch.count > 0 do net_send(from, &batch)
		game_status(fmt.tprintf("%s JOINED", fixed_str(msg.name[:])))

	case .Join_Accept:
		if nett.role != .Client || !nett.joining do return
		msg, mok := msg_as(Msg_Join_Accept, data)
		if !mok do return
		nett.joining = false
		nett.last_snap = 0
		game_enter_session(int(msg.id))

	case .Join_Deny:
		if nett.role != .Client || !nett.joining do return
		msg, mok := msg_as(Msg_Join_Deny, data)
		if !mok do return
		nett.joining = false
		switch msg.reason {
		case .Bad_Password:
			game_status("JOIN DENIED: WRONG PASSWORD")
		case .Server_Full:
			game_status("JOIN DENIED: SERVER FULL")
		case .Bad_Protocol:
			game_status("JOIN DENIED: VERSION MISMATCH")
		}

	case .State:
		if nett.role != .Host do return
		msg, mok := msg_as(Msg_State, data)
		if !mok do return
		id := int(msg.id)
		if id < 0 || id >= MAX_PLAYERS || !nett.clients[id].used || nett.clients[id].ep != from do return
		nett.clients[id].last_seen = 0
		net_apply_state(id, msg.state)

	case .Snapshot:
		if nett.role != .Client || from != nett.server_ep do return
		msg, mok := msg_as(Msg_Snapshot, data)
		if !mok do return
		nett.last_snap = 0
		for id in 0 ..< MAX_PLAYERS {
			live := (msg.active & (1 << u8(id))) != 0
			if id == game.local_id do continue
			if live {
				net_apply_state(id, msg.states[id])
				game.names[id] = msg.names[id]
				game.colors[id] = msg.colors[id]
			} else {
				game.active[id] = false
			}
		}

	case .Shot:
		msg, mok := msg_as(Msg_Shot, data)
		if !mok do return
		if int(msg.shooter) == game.local_id do return
		game_remote_shot(msg^)
		// host relays to everyone else
		if nett.role == .Host {
			for c, id in nett.clients {
				if c.used && id != int(msg.shooter) do net_send(c.ep, msg)
			}
		}

	case .Hit:
		msg, mok := msg_as(Msg_Hit, data)
		if !mok do return
		target := int(msg.target)
		if target == game.local_id {
			player_damage(game.local_id, msg.damage)
		} else if nett.role == .Host &&
		   target >= 0 &&
		   target < MAX_PLAYERS &&
		   nett.clients[target].used {
			net_send(nett.clients[target].ep, msg)
		}

	case .Leave:
		msg, mok := msg_as(Msg_Simple, data)
		if !mok do return
		id := int(msg.id)
		if nett.role == .Host &&
		   id >= 0 &&
		   id < MAX_PLAYERS &&
		   nett.clients[id].used &&
		   nett.clients[id].ep == from {
			nett.clients[id].used = false
			game.active[id] = false
			game_status(fmt.tprintf("%s LEFT", fixed_str(game.names[id][:])))
		}

	case .Ping:
		if nett.role != .Host do return
		msg, mok := msg_as(Msg_Simple, data)
		if !mok do return
		pong := Msg_Simple {
			header = {NET_MAGIC, .Pong},
			id     = msg.id,
		}
		net_send(from, &pong)

	case .Pong:
		if nett.role != .Client do return
		nett.ping_ms = int((game.time - nett.ping_sent_at) * 1000)

	case .Voxel:
		msg, mok := msg_as(Msg_Voxel, data)
		if !mok do return
		if int(msg.sender) == game.local_id do return
		voxel_apply_op(msg.op, nett.role == .Host)
		if nett.role == .Host {
			for c, id in nett.clients {
				if c.used && id != int(msg.sender) do net_send(c.ep, msg)
			}
		}

	case .Voxel_Batch:
		if nett.role != .Client do return
		msg, mok := msg_as(Msg_Voxel_Batch, data)
		if !mok do return
		for i in 0 ..< min(int(msg.count), VOXEL_BATCH_MAX) {
			voxel_apply_op(msg.ops[i], false)
		}
	}
}

// broadcast a world edit (host applies+relays; client sends to host)
net_send_voxel_op :: proc(op: Voxel_Op) {
	if nett.role == .None do return
	msg := Msg_Voxel {
		header = {NET_MAGIC, .Voxel},
		sender = u8(game.local_id),
		op     = op,
	}
	if nett.role == .Host {
		for c in nett.clients {
			if c.used do net_send(c.ep, &msg)
		}
	} else {
		net_send(nett.server_ep, &msg)
	}
}

// send a shot event (to host, who relays)
net_send_shot :: proc(weapon: Weapon_Kind, origin, dir: Vec3, hit_t: f32) {
	if nett.role == .None do return
	msg := Msg_Shot {
		header  = {NET_MAGIC, .Shot},
		shooter = u8(game.local_id),
		weapon  = u8(weapon),
		origin  = origin,
		dir     = dir,
		hit_t   = hit_t,
	}
	if nett.role == .Host {
		for c in nett.clients {
			if c.used do net_send(c.ep, &msg)
		}
	} else {
		net_send(nett.server_ep, &msg)
	}
}

net_send_hit :: proc(target: int, damage: f32) {
	if nett.role == .None do return
	msg := Msg_Hit {
		header = {NET_MAGIC, .Hit},
		target = u8(target),
		damage = damage,
	}
	if nett.role == .Host {
		if nett.clients[target].used do net_send(nett.clients[target].ep, &msg)
	} else {
		net_send(nett.server_ep, &msg)
	}
}

net_discovery_tick :: proc(dt: f32) {
	if nett.role != .Client do return
	nett.discover_acc += dt
	if nett.discover_acc >= 1.0 {
		nett.discover_acc = 0
		net_broadcast_discover()
	}
}
