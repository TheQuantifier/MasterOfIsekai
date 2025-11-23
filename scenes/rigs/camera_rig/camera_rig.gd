extends Node3D
class_name CameraRig

# ── Node refs ────────────────────────────────────────────────────────────────
@onready var pivot_yaw: Node3D   = $PivotYaw
@onready var pivot_pitch: Node3D = $PivotYaw/PivotPitch
@onready var spring: SpringArm3D = $PivotYaw/PivotPitch/SpringArm3D
@onready var cam: Camera3D       = $PivotYaw/PivotPitch/SpringArm3D/Camera3D

# ── Config ───────────────────────────────────────────────────────────────────
@export var world_attached: bool = true
@export var view_enabled: bool = true   # toggle for all look input

# Local offsets (PivotPitch space)
@export var third_person_offset := Vector3(0.0, 4, 0.0)
@export var first_person_offset := Vector3(0.0, 1.65, 0.0)
@export var third_person_distance := 4.0
@export var lerp_speed := 14.0

# Look / limits / sensitivity
@export var yaw_limit_deg := 45.0
@export var min_pitch_deg := -60.0
@export var max_pitch_deg := 60.0
@export var look_sens := 2.0

# Auto-center
@export var recenter_enabled := true
@export var recenter_speed := 6.0

# View mode
@export var third_person_fov := 70.0
@export var first_person_fov := 75.0
@export var transition_time := 0.30

# The character's meshes are placed on this Visibility Layer (bit index).
# In 1P we clear this bit from the camera's cull_mask to hide the body.
@export var head_visibility_layer: int = 1   # must match Player.character_visibility_layer_index

# Auto-exposure
@export var use_auto_exposure: bool = false
@export var auto_exposure_min_iso: float = 100.0
@export var auto_exposure_max_iso: float = 1600.0
@export var auto_exposure_speed: float = 0.5
@export var auto_exposure_scale: float = 1.0
@export var camera_attributes: CameraAttributes

# ── Runtime ──────────────────────────────────────────────────────────────────
var _target: Node3D
var _yaw_orbit := 0.0
var _pitch_orbit := 0.0
var _is_first_person := false
var _tween: Tween

# ── API ──────────────────────────────────────────────────────────────────────
func configure(target: Node3D = null) -> void:
	if target != null:
		_target = target
	if is_instance_valid(_target) and world_attached:
		global_transform = _target.global_transform

	# Start centered
	_yaw_orbit = 0.0
	_pitch_orbit = 0.0

	if is_instance_valid(cam):
		cam.current = true
		_ensure_attributes()
		_apply_attributes()

	# Keep spring arm from colliding with the player or any child colliders
	_exclude_target_from_spring()

	_apply_view_mode(true)
	_apply_head_layer_for_current_mode()  # ensure correct cull_mask at start

func set_target(target: Node3D) -> void:
	_target = target
	_exclude_target_from_spring()

func set_first_person(enable: bool) -> void:
	if _is_first_person == enable:
		return
	_is_first_person = enable
	# We’re not changing yaw on mode switch; only distance/anchor
	_transition_view()
	_apply_head_layer_for_current_mode()

# ── Process ──────────────────────────────────────────────────────────────────
func _process(delta: float) -> void:
	if not is_instance_valid(_target):
		return

	if world_attached:
		global_transform.origin = _target.global_transform.origin

	# Base yaw: same formula in both modes so switching 1P/3P doesn’t twist view
	var base_yaw := _compute_base_yaw()

	# Input
	var look_x := 0.0
	var look_y := 0.0
	if view_enabled:
		look_x = Input.get_action_strength("look_right") - Input.get_action_strength("look_left")
		look_y = Input.get_action_strength("look_up") - Input.get_action_strength("look_down")

	var yaw_step := deg_to_rad(look_sens) * look_x
	var pitch_step := deg_to_rad(look_sens) * look_y
	var yaw_half := deg_to_rad(yaw_limit_deg)

	# Update look offsets (or bleed back to center)
	if view_enabled:
		if !is_zero_approx(look_x):
			_yaw_orbit = clamp(_yaw_orbit - yaw_step, -yaw_half, yaw_half)
		elif recenter_enabled:
			_yaw_orbit = move_toward(_yaw_orbit, 0.0, recenter_speed * delta)

		if !is_zero_approx(look_y):
			_pitch_orbit += pitch_step
		elif recenter_enabled:
			_pitch_orbit = move_toward(_pitch_orbit, 0.0, recenter_speed * delta)
		_pitch_orbit = clamp(_pitch_orbit, deg_to_rad(min_pitch_deg), deg_to_rad(max_pitch_deg))
	else:
		_yaw_orbit   = move_toward(_yaw_orbit,   0.0, recenter_speed * delta)
		_pitch_orbit = move_toward(_pitch_orbit, 0.0, recenter_speed * delta)

	# Apply orbit (identical logic; arm length is the only difference)
	pivot_yaw.rotation.y = base_yaw + _yaw_orbit
	pivot_pitch.rotation.x = _pitch_orbit
	cam.rotation = Vector3.ZERO

	# Anchor point (eye vs shoulder) and arm length
	var desired_local := (first_person_offset if _is_first_person else Vector3(third_person_offset.x, third_person_offset.y, 0.0))
	pivot_pitch.position = pivot_pitch.position.lerp(desired_local, clamp(lerp_speed * delta, 0.0, 1.0))

	var target_len := 0.0 if _is_first_person else third_person_distance
	if spring.spring_length != target_len:
		spring.spring_length = lerp(spring.spring_length, target_len, clamp(lerp_speed * delta, 0.0, 1.0))

# ── Helpers ──────────────────────────────────────────────────────────────────
func _compute_base_yaw() -> float:
	# If the rig is parented under the Player (world_attached == false),
	# it already inherits Player yaw; just look behind (PI).
	# If world-attached, we must add Player yaw explicitly.
	return (_get_forward_yaw(_target) + PI) if world_attached else PI

func _get_forward_yaw(node: Node3D) -> float:
	if node == null:
		return 0.0
	if node.has_method("get_forward_yaw"):
		return node.get_forward_yaw()
	return node.rotation.y

# Exclude the player and ALL of its child CollisionObject3D from spring arm collision.
func _exclude_target_from_spring() -> void:
	if not is_instance_valid(spring) or not is_instance_valid(_target):
		return
	_exclude_colliders_recursive(_target)
	if _target is CollisionObject3D:
		var co := _target as CollisionObject3D
		spring.collision_mask = spring.collision_mask & ~co.collision_layer

func _exclude_colliders_recursive(n: Node) -> void:
	if n is CollisionObject3D:
		var rid := (n as CollisionObject3D).get_rid()
		spring.add_excluded_object(rid)
	for c in n.get_children():
		_exclude_colliders_recursive(c)

# Apply FOV and anchor immediately/transitioned
func _apply_view_mode(immediate: bool = false) -> void:
	if not is_instance_valid(cam) or not is_instance_valid(spring):
		return
	cam.fov = (first_person_fov if _is_first_person else third_person_fov)
	var target_length := (0.0 if _is_first_person else third_person_distance)
	if immediate:
		spring.spring_length = target_length
		pivot_pitch.position = (first_person_offset if _is_first_person else Vector3(third_person_offset.x, third_person_offset.y, 0.0))

func _transition_view() -> void:
	if is_instance_valid(_tween):
		_tween.kill()
	# (Optional) tween FOV/near/position here if you want – omitted for now.

# Hide/show the character’s visibility layer based on current mode.
func _apply_head_layer_for_current_mode() -> void:
	if head_visibility_layer < 0 or not is_instance_valid(cam):
		return
	var bit := 1 << head_visibility_layer
	if _is_first_person:
		# Hide character in 1P
		cam.cull_mask = cam.cull_mask & ~bit
	else:
		# Show character in 3P
		cam.cull_mask = cam.cull_mask | bit

# (Kept for completeness; you can call this to force a specific state)
func _toggle_head_layer() -> void:
	_apply_head_layer_for_current_mode()

# Camera attributes
func _ensure_attributes() -> void:
	if camera_attributes == null:
		camera_attributes = CameraAttributesPractical.new()
	if cam:
		cam.attributes = camera_attributes

func _apply_attributes() -> void:
	_ensure_attributes()
	var attrs := camera_attributes
	if attrs == null:
		return
	attrs.auto_exposure_enabled = use_auto_exposure
	attrs.auto_exposure_min_sensitivity = auto_exposure_min_iso
	attrs.auto_exposure_max_sensitivity = auto_exposure_max_iso
	attrs.auto_exposure_speed = auto_exposure_speed
	attrs.auto_exposure_scale = auto_exposure_scale
