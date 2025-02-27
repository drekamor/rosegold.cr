require "../client"
require "./action"
require "./raytrace"

struct Int32
  def ticks
    self / 20
  end

  def tick
    ticks
  end
end

abstract class Rosegold::Event; end # defined elsewhere, but otherwise it would be a module

class Rosegold::Event::PhysicsTick < Rosegold::Event
  getter movement : Vec3d

  def initialize(@movement); end
end

# Updates the player feet/look/velocity/on_ground by sending movement packets.
class Rosegold::Physics
  DRAG    = 0.98 # y velocity multiplicator per tick when not on ground
  GRAVITY = 0.08 # m/t/t; subtracted from y velocity each tick when not on ground

  WALK_SPEED   = 4.3 / 20   # m/t
  SPRINT_SPEED = 5.612 / 20 # m/t
  SNEAK_SPEED  = 1.31 / 20  # m/t

  JUMP_FORCE = 0.42 # m/t; applied to velocity when starting a jump

  VERY_CLOSE = 0.00001 # consider arrived at target if squared distance is closer than this

  private getter client : Rosegold::Client
  private property ticker : Fiber?
  property? paused : Bool = true
  property? jump_queued : Bool = false
  private getter movement_action : Action(Vec3d)?
  private getter look_action : Action(Look)?
  private getter action_mutex : Mutex = Mutex.new

  def movement_target
    movement_action.try &.target
  end

  def look_target
    look_action.try &.target
  end

  def initialize(@client : Rosegold::Client); end

  def pause
    @paused = true
  end

  def handle_reset
    @paused = false
    player.velocity = Vec3d::ORIGIN

    ticker.try do |t|
      return unless t.dead?
    end
    self.ticker = spawn do
      while client.connected?
        tick
        sleep 1/20
      end
    end
  end

  # Set the movement target location and wait until it is achieved.
  # If there is already a movement target, it is cancelled, and replaced with this new target.
  # Set `target=nil` to stop moving and cancel any current movement.
  def move(target : Vec3d?)
    if target == nil
      action_mutex.synchronize do
        @movement_action.try &.fail "Movement stopped"
        @movement_action = nil
      end
      return
    end

    action = Action(Vec3d).new(target)
    action_mutex.synchronize do
      @movement_action.try &.fail "Replaced by movement to #{target}"
      @movement_action = action
    end
    action.join
  end

  # Set the look target and wait until it is achieved.
  # If there is already a look target, it is cancelled, and replaced with this new target.
  def look=(target : Look)
    action = Action.new(target)
    action_mutex.synchronize do
      @look_action.try &.fail "Replaced by look of #{target}"
      @look_action = action
    end
    action.join
  end

  def sneak(sneaking = true)
    # send nothing if already in desired state
    return if player.sneaking? == sneaking
    if sneaking
      # can't sprint while sneaking
      sprint false
      client.send_packet! Serverbound::EntityAction.new player.entity_id, :start_sneaking
    else
      client.send_packet! Serverbound::EntityAction.new player.entity_id, :stop_sneaking
    end
    player.sneaking = sneaking
  end

  def sprint(sprinting = true)
    # can't sprint while sneaking
    return if player.sneaking?
    # send nothing if already in desired state
    return if player.sprinting? == sprinting
    if sprinting
      client.send_packet! Serverbound::EntityAction.new player.entity_id, :start_sprinting
    else
      client.send_packet! Serverbound::EntityAction.new player.entity_id, :stop_sprinting
    end
    player.sprinting = sprinting
  end

  def movement_speed : Float64
    return SNEAK_SPEED if player.sneaking?
    return SPRINT_SPEED if player.sprinting?
    WALK_SPEED
  end

  private def player
    client.player
  end

  private def dimension
    client.dimension
  end

  def tick
    return if paused?
    return unless client.connected?

    input_velocity = velocity_for_inputs

    movement, next_velocity = Physics.predict_movement_collision(
      player.feet, input_velocity, Player::DEFAULT_AABB, dimension)

    look_action = action_mutex.synchronize do
      action = @look_action
      @look_action = nil
      action
    end
    look = look_action.try(&.target) || player.look

    feet = player.feet + movement
    # align with grid in case of rounding errors
    feet = feet.with_y feet.y.round(4)

    # TODO: this only works with gravity on
    on_ground = movement.y > input_velocity.y

    @movement_action.try &.fail "Stuck at #{feet}" unless feet != player.feet

    send_movement_packet feet, look, on_ground
    player.velocity = next_velocity

    action_mutex.synchronize do
      look_action.try &.succeed

      @movement_action.try do |movement_action|
        # movement_action.target only influences x,z; rely on stepping/falling to change y
        target_diff = (movement_action.target - player.feet).with_y(0)
        if target_diff.length < VERY_CLOSE
          movement_action.succeed
          @movement_action = nil
        end
      end
    end

    client.emit_event Event::PhysicsTick.new movement
  end

  private def send_movement_packet(feet : Vec3d, look : Look, on_ground : Bool)
    # anticheat requires sending these different packets
    if feet != player.feet
      if look != player.look
        client.send_packet! Serverbound::PlayerPositionAndLook.new(
          feet, look, on_ground)
      else
        client.send_packet! Serverbound::PlayerPosition.new feet, on_ground
      end
    else
      if look != player.look
        client.send_packet! Serverbound::PlayerLook.new look, on_ground
      else
        client.send_packet! Serverbound::PlayerNoMovement.new on_ground
      end
    end
    player.feet = feet
    player.look = look
    player.on_ground = on_ground
  end

  private def velocity_for_inputs
    curr_movement = @movement_action
    if curr_movement
      # curr_movement.target only influences x,z; rely on stepping/falling to change y
      move_horiz_vec = (curr_movement.target - player.feet).with_y(0)
      move_horiz_vec_len = move_horiz_vec.length
      if move_horiz_vec_len < VERY_CLOSE
        move_horiz_vec = Vec3d::ORIGIN
      elsif move_horiz_vec_len > movement_speed
        # take one step of the length of movement_speed
        move_horiz_vec *= movement_speed / move_horiz_vec_len
      end # else: get there in one step
    else
      move_horiz_vec = Vec3d::ORIGIN
    end

    if jump_queued? && player.on_ground?
      @jump_queued = false
      vel_y = JUMP_FORCE
    else
      vel_y = (player.velocity.y - GRAVITY) * DRAG
    end

    # TODO floating up water/ladders

    Vec3d.new move_horiz_vec.x, vel_y, move_horiz_vec.z
  end

  # Applies collision handling including stepping.
  # Returns adjusted movement vector and adjusted post-movement velocity.
  def self.predict_movement_collision(start : Vec3d, velocity : Vec3d, entity_aabb : AABBf, dimension : Dimension)
    obstacles = get_grown_obstacles start, velocity, entity_aabb, dimension
    predict_movement_collision start, velocity, obstacles
  end

  # :ditto:
  def self.predict_movement_collision(start : Vec3d, velocity : Vec3d, obstacles : Array(AABBd))
    # we can freely move in blocks that we already collide with before the movement
    obstacles = obstacles.reject &.contains? start

    movement = slide start, velocity, obstacles
    collided_x = movement.x != velocity.x
    collided_y = movement.y != velocity.y
    collided_z = movement.z != velocity.z

    if collided_x || collided_z
      step_up_movement = slide start, Vec3d.new(0, 0.5, 0), obstacles
      step_up = start + step_up_movement
      # gravity would pull us into the step, preventing stepping
      over_velocity = velocity.with_y 0
      step_over_movement = slide step_up, over_velocity, obstacles

      step_different_x = step_over_movement.x != movement.x
      step_different_z = step_over_movement.z != movement.z
      if step_different_x || step_different_z
        # we may have stepped too far up, land on top surface of step block
        step_over = step_up + step_over_movement
        down_velocity = Vec3d.new(0, velocity.y - step_up_movement.y, 0)
        down_end = step_over + slide step_over, down_velocity, obstacles
        movement = down_end - start
        collided_x = movement.x != velocity.x
        collided_y = true
        collided_z = movement.z != velocity.z
      end
    end

    new_velocity = velocity
    new_velocity = new_velocity.with_x 0 if collided_x
    new_velocity = new_velocity.with_y 0 if collided_y
    new_velocity = new_velocity.with_z 0 if collided_z

    {movement, new_velocity}
  end

  # Slide along block faces in three dimensions.
  private def self.slide(start, velocity, obstacles)
    (1..3).each do
      collision = Raytrace.raytrace start, velocity, obstacles
      return velocity unless collision
      # slide parallel to this face
      coord = (collision.intercept - start).axis collision.face
      velocity = velocity.with_axis collision.face, coord
    end
    velocity
  end

  # Returns all block collision boxes that may intersect `entity_aabb` during the movement from `start` by `vec`,
  # including boxes 0.5m higher for stepping.
  # `entity_aabb` is at 0,0,0; the returned AABBs are grown by `entity_aabb` so collision checks are just raytracing.
  def self.get_grown_obstacles(
    start : Vec3d, movement : Vec3d, entity_aabb : AABBf, dimension : Dimension
  ) : Array(AABBd)
    entity_aabb = entity_aabb.to_f64
    grow_aabb = entity_aabb * -1
    # get all blocks that may potentially collide
    bounds = AABBd.containing_all(
      entity_aabb.offset(start),
      entity_aabb.offset(start + movement))
    # fences are 1.5m tall
    min_block = bounds.min.down(0.5).block
    # add maximum stepping height (0.5) so we can reuse the obstacles when stepping
    max_block = bounds.max.up(0.5).block
    blocks_coords = Indexable.cartesian_product({
      (min_block.x..max_block.x).to_a,
      (min_block.y..max_block.y).to_a,
      (min_block.z..max_block.z).to_a,
    })
    blocks_coords.flat_map do |block_coords|
      x, y, z = block_coords
      dimension.block_state(x, y, z).try do |block_state|
        block_shape = MCData::MC118.block_state_collision_shapes[block_state]
        block_shape.map &.to_f64.offset(x, y, z).grow(grow_aabb)
      end || Array(AABBd).new 0 # outside world or outside loaded chunks - XXX make solid so we don't fall through unloaded chunks
    end
  end
end
