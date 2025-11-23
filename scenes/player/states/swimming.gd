extends PlayerState

func enter(_prev):
	print("[STATE] Enter SWIMMING")
	owner._bob_t = 0.0

func physics_update(delta: float) -> void:
	if not owner.in_water:
		print("[STATE] Leaving SWIMMING")

		if owner.is_on_floor():
			owner.change_state(owner.st_grounded)
		else:
			owner.change_state(owner.st_airborne)
		return

	var was_on_floor := owner.is_on_floor()

	# Input
	var is_moving_forward := Input.is_action_pressed("move_forward")
	var is_moving_backward := Input.is_action_pressed("move_back")
	var is_strafe_left := Input.is_action_pressed("strafe_left")
	var is_strafe_right := Input.is_action_pressed("strafe_right")
	var is_crouching := Input.is_action_pressed("crouch")
	var is_sprinting := Input.is_action_pressed("sprint")
	var jump_held := Input.is_action_pressed("jump")

	# Turning in water
	var turn_rate : float = owner.settings.water_turn_speed
	if Input.is_action_pressed("move_left"):
		owner.rotate_y(turn_rate * delta)
	if Input.is_action_pressed("move_right"):
		owner.rotate_y(-turn_rate * delta)

	# Horizontal movement
	var axes : Dictionary = owner.compute_local_axes()
	var fwd: Vector3 = axes.fwd
	var right: Vector3 = axes.right

	var direction := Vector3.ZERO
	if is_moving_forward: direction += fwd
	if is_moving_backward: direction -= fwd
	if is_strafe_right: direction -= right
	if is_strafe_left: direction += right
	if direction != Vector3.ZERO:
		direction = direction.normalized()

	var speed : float = owner.common_speed_select(direction, is_moving_forward, is_crouching, is_sprinting, was_on_floor)
	owner.apply_horizontal_velocity(direction, speed, false)

	# Apply Waterways flow
	if owner.current_water_flow != Vector3.ZERO:
		var flow: Vector3 = owner.current_water_flow
		flow.y = 0.0
		if flow.length() > 0.01:
			owner.velocity.x += flow.x * owner.water_flow_force * delta
			owner.velocity.z += flow.z * owner.water_flow_force * delta

	# Vertical swimming logic
	owner._handle_water_vertical(delta, jump_held)

	# Move
	owner.move_and_slide()

	# Cache grounded state
	owner._grounded_cached = owner.is_on_floor()
	owner._was_in_water_last_frame = true

	owner._handle_animations(is_moving_forward, is_moving_backward, is_crouching, is_sprinting, owner._grounded_cached)
