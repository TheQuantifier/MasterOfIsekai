extends CharacterBody3D
class_name Player

@export var settings: PlayerSettings   # link your .tres in the inspector

@onready var character_node: Node3D = $Character
@onready var camera_rig: CameraRig = $CameraRig

# Imported character model -> visibility layer
@export var character_visibility_layer_index: int = 1

# -------------------------------------------------------------------
# Animation state
# -------------------------------------------------------------------
var anim_player: AnimationPlayer
var is_jumping: bool = false

# -------------------------------------------------------------------
# Water state (integrated with Waterways)
# -------------------------------------------------------------------
var in_water: bool = false
var _was_in_water_last_frame: bool = false

# -------------------------------------------------------------------
# Bobbing control
# -------------------------------------------------------------------
var _bob_t: float = 0.0
const WATER_STILL_EPS: float = 0.2
const LAND_STILL_EPS: float = 0.05

# -------------------------------------------------------------------
# Ground stick helpers
# -------------------------------------------------------------------
@export var stick_force: float = 2.0
@export var floor_snap_len: float = 1.5
@export_range(0.0, 89.0) var floor_max_angle_deg: float = 50.0

# -------------------------------------------------------------------
# Grounded cache
# -------------------------------------------------------------------
var _grounded_cached: bool = false

# -------------------------------------------------------------------
# State Machine
# -------------------------------------------------------------------
var state        # PlayerState
var st_grounded  # PlayerState
var st_airborne  # PlayerState
var st_swimming  # PlayerState

func change_state(next_state) -> void:
	if state == next_state or next_state == null:
		return
	var prev: PlayerState = state
	if prev and prev.has_method("exit"):
		prev.exit(next_state)
	state = next_state
	if state and state.has_method("enter"):
		state.enter(prev)

# -------------------------------------------------------------------
# Waterways integration
# -------------------------------------------------------------------
@export var use_waterways: bool = true
@export var water_detect_margin: float = 1.0
@export var water_flow_force: float = 2.0

var current_water_flow: Vector3 = Vector3.ZERO

# -------------------------------------------------------------------
# Lifecycle
# -------------------------------------------------------------------
func _ready() -> void:
	if settings == null:
		push_warning("Player: No PlayerSettings assigned. Using defaults.")
		settings = PlayerSettings.new()
	load_model_from_character_data()

	# CharacterBody3D setup
	floor_snap_length = floor_snap_len
	floor_max_angle = deg_to_rad(floor_max_angle_deg)
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED

	# CameraRig
	if is_instance_valid(camera_rig):
		camera_rig.world_attached = false
		camera_rig.configure(self)
	else:
		push_warning("Player: CameraRig child not found.")

	# --- States ---
	st_grounded = load("res://scenes/player/states/grounded.gd").new()
	st_airborne = load("res://scenes/player/states/airborne.gd").new()
	st_swimming = load("res://scenes/player/states/swimming.gd").new()

	for s in [st_grounded, st_airborne, st_swimming]:
		s.owner = self

	# Pick initial state
	if in_water:
		change_state(st_swimming)
	elif is_on_floor():
		change_state(st_grounded)
	else:
		change_state(st_airborne)

# -------------------------------------------------------------------
# Model loading
# -------------------------------------------------------------------
func load_model_from_character_data() -> void:
	for child in character_node.get_children():
		child.queue_free()

	var model_path: String = game_manager.current_character.model_path
	if model_path.is_empty():
		push_error("No model path defined in current character.")
		return

	var model_scene := load(model_path)
	if model_scene is PackedScene:
		var model_instance: Node3D = model_scene.instantiate()
		character_node.add_child(model_instance)

		var layer_idx := character_visibility_layer_index
		if is_instance_valid(camera_rig) and camera_rig.head_visibility_layer >= 0:
			layer_idx = camera_rig.head_visibility_layer
		_set_visibility_layer_recursive(model_instance, layer_idx)

		anim_player = model_instance.get_node_or_null("AnimationPlayer")
		if anim_player == null:
			push_warning("No AnimationPlayer found in loaded model.")
	else:
		push_error("Failed to load model at path: " + model_path)

func _set_visibility_layer_recursive(node: Node, layer_index: int) -> void:
	var bit := 1 << layer_index
	if node is GeometryInstance3D:
		var gi := node as GeometryInstance3D
		gi.layers = bit
	for c in node.get_children():
		_set_visibility_layer_recursive(c, layer_index)

# -------------------------------------------------------------------
# Waterways helpers
# -------------------------------------------------------------------
func _get_nearest_river_sample() -> Dictionary:
	var pos: Vector3 = global_transform.origin
	var best_height := -INF
	var best_flow := Vector3.ZERO
	var found := false

	for node in get_tree().get_nodes_in_group("river_float"):
		if node == null:
			continue
		var h: float = node.GetWaterHeight(pos)
		var default_h: float = node.DefaultHeight

		if abs(h - default_h) < 0.01:
			continue  # no hit

		if not found or h > best_height:
			found = true
			best_height = h
			best_flow = node.GetWaterFlowDirection(pos)

	return {
		"found": found,
		"height": best_height,
		"flow": best_flow,
	}

func _update_water_state_from_waterways() -> void:
	if not use_waterways:
		return

	var sample := _get_nearest_river_sample()
	_was_in_water_last_frame = in_water

	if sample.found:
		# Debug the raw river height & flow
		print("[RIVER] Surface height: ", sample.height, " Flow: ", sample.flow)
		var water_height: float = sample.height
		current_water_flow = sample.flow

		settings.water_surface_height = water_height

		var threshold := settings.surface_offset + water_detect_margin
		var inside := global_position.y <= water_height + threshold

		if inside != in_water:
			set_in_water(inside)
	else:
		current_water_flow = Vector3.ZERO
		if in_water:
			set_in_water(false)

# -------------------------------------------------------------------
# Physics
# -------------------------------------------------------------------
func _physics_process(delta: float) -> void:
	_update_water_state_from_waterways()
	if state:
		state.physics_update(delta)

# Helpers
func compute_local_axes() -> Dictionary:
	var fwd := transform.basis.z;  fwd.y = 0.0;  fwd = fwd.normalized()
	var right := transform.basis.x; right.y = 0.0; right = right.normalized()
	return {"fwd": fwd, "right": right}

func common_speed_select(direction: Vector3, is_moving_forward: bool, is_crouching: bool, is_sprinting: bool, was_on_floor: bool) -> float:
	var speed: float = settings.move_speed
	if is_sprinting and is_moving_forward and not is_crouching and not in_water:
		speed = settings.sprint_speed
	if is_crouching and direction != Vector3.ZERO and not in_water:
		speed = settings.crouch_speed
	if not was_on_floor and not in_water:
		speed = settings.airborne_speed
	if in_water:
		if is_sprinting and is_moving_forward and not is_crouching:
			speed = settings.water_sprint_speed
		else:
			speed = settings.water_speed
	return speed

func apply_horizontal_velocity(direction: Vector3, speed: float, was_on_floor: bool) -> void:
	if was_on_floor and not in_water:
		var flat_vel := (direction * speed).slide(get_floor_normal())
		velocity.x = flat_vel.x
		velocity.z = flat_vel.z
	else:
		velocity.x = direction.x * speed
		velocity.z = direction.z * speed

func land_gravity_and_stick(delta: float, was_on_floor: bool) -> void:
	if not was_on_floor:
		velocity.y -= settings.gravity * delta
	else:
		velocity.y = -stick_force

func _handle_water_vertical(delta: float, jump_held: bool) -> void:
	if not _was_in_water_last_frame:
		velocity.y = clamp(velocity.y, -settings.bob_max_speed, settings.bob_max_speed)

	var surface: float = settings.water_surface_height + settings.surface_offset

	if settings.enable_surface_hold and jump_held:
		var offset: float = 0.0
		if settings.enable_bob and settings.bob_height > 0.0 and settings.bob_speed > 0.0:
			_bob_t += delta
			offset = sin(TAU * settings.bob_speed * _bob_t) * settings.bob_height

		var target_y: float = surface + offset
		var error: float = target_y - global_position.y
		var desired_vy: float = clamp(error * settings.bob_follow_accel, -settings.bob_max_speed, settings.bob_max_speed)
		velocity.y = move_toward(velocity.y, desired_vy, settings.bob_follow_accel * delta)
	else:
		velocity.y = max(velocity.y - settings.water_sink_accel * delta, -settings.max_sink_speed)

# -------------------------------------------------------------------
# Animations
# -------------------------------------------------------------------
func _handle_animations(is_moving_forward: bool, is_moving_backward: bool, is_crouching: bool, is_sprinting: bool, now_on_floor: bool) -> void:
	if anim_player == null:
		return

	if in_water:
		var planar_speed: float = Vector2(velocity.x, velocity.z).length()
		var moving_horizontally: bool = is_moving_forward or is_moving_backward
		var standing_still_in_water: bool = (not moving_horizontally) and (planar_speed <= WATER_STILL_EPS)

		if standing_still_in_water:
			_play("treading", settings.anim_treading)
		elif is_sprinting and is_moving_forward and not is_crouching:
			_play("swimming", settings.anim_swim_sprint)
		else:
			_play("swimming", settings.anim_swim)
	elif is_jumping and not now_on_floor:
		pass
	elif now_on_floor:
		if is_jumping:
			is_jumping = false

		if is_crouching:
			if is_moving_forward:
				_play("crouch_move_forward", settings.anim_crouch_run)
			elif is_moving_backward:
				_play("crouch_move_back", settings.anim_crouch_run_backward)
			else:
				_play("crouch_idle", settings.anim_crouch_idle)
		elif is_moving_forward:
			_play("run", (settings.anim_sprint if is_sprinting else settings.anim_run), (-1.0 if is_sprinting else settings.anim_smoothness))
		elif is_moving_backward:
			_play("run_backward", (settings.anim_sprint_backward if is_sprinting else settings.anim_run_backward))
		else:
			_play("idle", settings.anim_idle)

# -------------------------------------------------------------------
# Hooks + API used by states
# -------------------------------------------------------------------
func set_in_water(value: bool) -> void:
	if value and not in_water:
		print("[WATER] Entering water at height: ", settings.water_surface_height)
	elif not value and in_water:
		print("[WATER] Exiting water")
		
	if value and not in_water:
		_bob_t = 0.0

	in_water = value

	if in_water:
		change_state(st_swimming)
	else:
		if is_on_floor():
			change_state(st_grounded)
		else:
			change_state(st_airborne)

func set_first_person(enable: bool) -> void:
	if is_instance_valid(camera_rig) and camera_rig.has_method("set_first_person"):
		camera_rig.set_first_person(enable)

func get_forward_yaw() -> float:
	return rotation.y

func get_forward_basis() -> Basis:
	return global_transform.basis

func _play(anim_name: String, rate: float, _smoothness: float = settings.anim_smoothness) -> void:
	if anim_player == null:
		return
	if anim_player.current_animation != anim_name:
		anim_player.play(anim_name, _smoothness, rate)
	else:
		anim_player.speed_scale = rate

func can_be_safely_saved() -> bool:
	return _grounded_cached and not in_water
