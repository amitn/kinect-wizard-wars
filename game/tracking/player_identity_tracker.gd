class_name PlayerIdentityTracker
extends RefCounted
## Keeps Player 1 / Player 2 stable across frames by matching new detections to
## remembered players by hips-centre distance. Crossing players may swap when
## they overlap for long; normal play stays stable.

var max_match_distance := 0.7   # meters
var memory_s := 1.5             # a player is kept this long without a detection

var players: Dictionary = {}    # id -> TrackedPlayer
var _next_id := 1


## `detections` are Arrays of raw joint data produced by PoseProcessor; each has
## a "root" Vector3. Returns the matched TrackedPlayer for each detection.
func assign(detections: Array, now: float) -> Array:
	var assigned: Array = []
	var used: Dictionary = {}
	# Match the players seen most recently first.
	var ids := players.keys()
	ids.sort_custom(func(a, b): return players[a].last_seen > players[b].last_seen)
	var taken: Dictionary = {}
	for pid in ids:
		var p: TrackedPlayer = players[pid]
		var best := -1
		var best_d := max_match_distance
		for k in detections.size():
			if used.has(k):
				continue
			var d: float = Vector2(detections[k]["root"].x, detections[k]["root"].z).distance_to(Vector2(p.position.x, p.position.z))
			if d < best_d:
				best_d = d
				best = k
		if best >= 0:
			used[best] = true
			taken[best] = p
	for k in detections.size():
		if taken.has(k):
			assigned.append(taken[k])
		else:
			var p := TrackedPlayer.new()
			p.id = _next_id
			_next_id += 1
			players[p.id] = p
			assigned.append(p)
	return assigned


func expire(now: float) -> Array:
	var gone: Array = []
	for pid in players.keys():
		if now - players[pid].last_seen > memory_s:
			gone.append(players[pid])
			players.erase(pid)
	return gone
