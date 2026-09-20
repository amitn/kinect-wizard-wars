extends Node
## Autoload "Audio": every sound the game makes.
##
##   Audio.play("bolt_fire", wizard.position.x)   # placed left or right by where it happens
##   Audio.ui("ui_select")                        # interface sounds, centred
##   Audio.set_battle(true)                       # drums and pulse fade in over the calm layer
##   Audio.duck(-9.0, 2.5)                        # music steps back for a big moment
##
## All of it is synthesized by tools/make_sounds.cpp into res://audio. Two buses,
## "Music" and "SFX", follow the volume settings. A missing file is a silent
## sound, not an error, and everything keeps running while the game is paused so
## the settings menu has its clicks and the music does not stop under it.

## Mix level of each effect in dB. The files all peak at -1 dBFS; how loud a
## sound should be in the game is decided here, not in the synth.
const SOUNDS := {
	"bolt_fire": -6.0, "bolt_water": -5.0, "wave_fire": -4.0, "wave_water": -3.0,
	"shield_up": -9.0, "shield_down": -11.0, "shield_block": -3.0,
	"hit_fire": -3.0, "hit_water": -1.5, "clash": -6.0, "heal": -6.0, "fizzle": -12.0,
	"count": -8.0, "fight": -3.0, "ko": -1.0, "victory": -7.0,
	"join": -12.0, "leave": -14.0,
	"ui_move": -20.0, "ui_select": -16.0, "ui_open": -16.0, "ui_close": -17.0,
}
const POLYPHONY := 12          # spells, hits and shields can pile up in a busy second
const RETRIGGER_S := 0.05      # the same sound twice within this is one event reported twice
const MUSIC_DB := -13.0        # the calm layer, under the effects
const BATTLE_DB := -2.0        # the battle layer relative to the calm one, when fully in
const BATTLE_FADE_S := 1.8
const SCREEN_CENTER := Vector2(960.0, 540.0)

var _streams: Dictionary = {}             # name -> AudioStream
var _world: Array[AudioStreamPlayer2D] = []
var _flat: Array[AudioStreamPlayer] = []
var _last_played: Dictionary = {}         # name -> seconds
var _music: AudioStreamPlayer = null
var _layers: AudioStreamSynchronized = null
var _battle := 0.0                        # 0 calm only .. 1 battle layer fully in
var _battle_target := 0.0
var _duck_db := 0.0
var _duck_until := 0.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			var index := AudioServer.bus_count - 1
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")
	for sound_name in SOUNDS:
		var path := "res://audio/%s.wav" % sound_name
		if ResourceLoader.exists(path):
			_streams[sound_name] = load(path)
	for i in POLYPHONY:
		var player := AudioStreamPlayer2D.new()
		player.bus = "SFX"
		# Placement is for left and right only: no fading with distance.
		player.max_distance = 8000.0
		player.attenuation = 0.05
		player.panning_strength = 3.0
		add_child(player)
		_world.append(player)
	for i in 4:
		var player := AudioStreamPlayer.new()
		player.bus = "SFX"
		add_child(player)
		_flat.append(player)
	_start_music()
	_apply_volumes()
	Settings.changed.connect(func(key: String):
		if key == "music_volume" or key == "sfx_volume":
			_apply_volumes())


## An effect in the arena. `x` is the screen position it comes from (0..1920):
## the fire wizard's sounds sit to the left, the water wizard's to the right.
func play(sound_name: String, x: float = SCREEN_CENTER.x, extra_db: float = 0.0, pitch_jitter: float = 0.05, pitch: float = 1.0) -> void:
	var stream: AudioStream = _stream_for(sound_name)
	if stream == null:
		return
	var player := _free_world_player()
	player.stream = stream
	player.global_position = Vector2(clampf(x, 0.0, SCREEN_CENTER.x * 2.0), SCREEN_CENTER.y)
	player.volume_db = float(SOUNDS[sound_name]) + extra_db
	player.pitch_scale = pitch * (1.0 + randf_range(-pitch_jitter, pitch_jitter))
	player.play()


## An interface or announcer sound: centred, never pitch-shifted.
func ui(sound_name: String, extra_db: float = 0.0) -> void:
	var stream: AudioStream = _stream_for(sound_name)
	if stream == null:
		return
	var player: AudioStreamPlayer = _flat[0]
	for candidate in _flat:
		if not candidate.playing:
			player = candidate
			break
	player.stream = stream
	player.volume_db = float(SOUNDS[sound_name]) + extra_db
	player.play()


## true: the fight is on and the drums come in. false: back to the calm layer alone.
func set_battle(active: bool) -> void:
	_battle_target = 1.0 if active else 0.0


## Pull the music down by `db` (negative) for `seconds`, then let it come back.
func duck(db: float, seconds: float) -> void:
	_duck_db = db
	_duck_until = Time.get_ticks_msec() / 1000.0 + seconds


func _stream_for(sound_name: String) -> AudioStream:
	if not _streams.has(sound_name):
		return null
	var now := Time.get_ticks_msec() / 1000.0
	if now - float(_last_played.get(sound_name, -1.0)) < RETRIGGER_S:
		return null
	_last_played[sound_name] = now
	return _streams[sound_name]


func _free_world_player() -> AudioStreamPlayer2D:
	var oldest: AudioStreamPlayer2D = _world[0]
	for player in _world:
		if not player.playing:
			return player
		if player.get_playback_position() > oldest.get_playback_position():
			oldest = player
	return oldest   # everything is busy: the one nearest its end gives way


func _start_music() -> void:
	var calm_path := "res://audio/music_calm.ogg"
	var battle_path := "res://audio/music_battle.ogg"
	if not ResourceLoader.exists(calm_path) or not ResourceLoader.exists(battle_path):
		return
	var calm: AudioStreamOggVorbis = load(calm_path)
	var battle: AudioStreamOggVorbis = load(battle_path)
	# Import settings are not in the repository, so looping is switched on here.
	calm.loop = true
	battle.loop = true
	# The two layers are the same 40 s, bar for bar; played in sync, the battle
	# layer's volume is the only thing that changes between waiting and fighting.
	_layers = AudioStreamSynchronized.new()
	_layers.stream_count = 2
	_layers.set_sync_stream(0, calm)
	_layers.set_sync_stream(1, battle)
	_layers.set_sync_stream_volume(0, 0.0)
	_layers.set_sync_stream_volume(1, -60.0)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	_music.stream = _layers
	_music.volume_db = MUSIC_DB
	add_child(_music)
	_music.play()


## Players still sounding when the engine shuts down are reported as leaks.
func _exit_tree() -> void:
	for player in _world:
		player.stop()
	for player in _flat:
		player.stop()
	if _music != null:
		_music.stop()
		_music.stream = null
	_layers = null


func _process(delta: float) -> void:
	if _music == null:
		return
	_battle = move_toward(_battle, _battle_target, delta / BATTLE_FADE_S)
	_layers.set_sync_stream_volume(1, linear_to_db(maxf(_battle * _battle, 0.001)) + BATTLE_DB)
	var ducked := _duck_db if Time.get_ticks_msec() / 1000.0 < _duck_until else 0.0
	_music.volume_db = lerpf(_music.volume_db, MUSIC_DB + ducked, clampf(delta * 5.0, 0.0, 1.0))


func _apply_volumes() -> void:
	for pair in [["Music", Settings.music_volume], ["SFX", Settings.sfx_volume]]:
		var index := AudioServer.get_bus_index(pair[0])
		var level: int = pair[1]
		AudioServer.set_bus_mute(index, level <= 0)
		AudioServer.set_bus_volume_db(index, linear_to_db(maxf(level, 1) / 100.0))
