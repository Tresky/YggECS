package main

import ecs "../src"

import "core:testing"
import "core:time"
import "core:fmt"
import "core:prof/spall"
import "core:sync"
import "base:runtime"

spall_ctx: spall.Context
@(thread_local) spall_buffer: spall.Buffer

Position :: struct {
	x, y: f32,
}

Velocity :: struct {
	x, y: f32,
}

Health :: struct {
	value: int,
}

Contains :: struct {
	amount: int,
}

@(test)
test_query_and_components :: proc(t: ^testing.T) {
    using ecs
	world := create_world();defer delete_world(world)

	gold := ecs.add_entity(world)

	player := add_entity(world)
	add_component(world, player, Position{x = 10, y = 20})
	add_component(world, player, Velocity{x = 1, y = 1})

	enemy := add_entity(world)
	add_component(world, enemy, Position{x = 50, y = 60})
	add_component(world, enemy, Health{value = 100})

	item := add_entity(world)
	add_component(world, item, Position{x = 30, y = 40})
	add_component(world, item, pair(Contains{12}, gold))

	result1 := query(world, has(Position), not(pair(Contains, gold)))
	testing.expect(
		t,
		len(result1) > 0,
		"Should have entities with Position but not Contains(gold)",
	)

	result2 := query(world, has(Position))
	testing.expect(t, len(result2) > 0, "Should have entities with Position")

	result3 := query(world, has(Position), pair(Contains, gold))
	testing.expect(t, len(result3) > 0, "Should have entities with Position and Contains(gold)")

	result4 := query(world, has(Position), pair(Contains, gold))
	testing.expect(t, len(result4) > 0, "Should have entities with Position and Contains(12 gold)")
}

@(test)
test_hash_archetype :: proc(t: ^testing.T) {
    using ecs
    world := create_world()
    defer delete_world(world)

    // Register some components to get consistent IDs
    pos_id := register_component(world, Position)
    vel_id := register_component(world, Velocity)
    health_id := register_component(world, Health)

    // Test same components in different orders give same hash
    components1 := []ComponentID{pos_id, vel_id, health_id}
    components2 := []ComponentID{vel_id, health_id, pos_id} 
    components3 := []ComponentID{health_id, pos_id, vel_id}

    hash1 := hash_archetype(components1, []ComponentID{})
    hash2 := hash_archetype(components2, []ComponentID{})
    hash3 := hash_archetype(components3, []ComponentID{})

    testing.expect(t, hash1 == hash2, "Hash should be same for same components in different order")
    testing.expect(t, hash2 == hash3, "Hash should be same for same components in different order")
    testing.expect(t, hash1 == hash3, "Hash should be same for same components in different order")

    // Test different components give different hashes
    components4 := []ComponentID{pos_id, vel_id}
    hash4 := hash_archetype(components4, []ComponentID{})

    testing.expect(t, hash1 != hash4, "Hash should be different for different components")

    // Test tags affect hash
    tag_components := []ComponentID{pos_id, vel_id}
    tag_ids := []ComponentID{health_id}
    hash_with_tags := hash_archetype(tag_components, tag_ids)

    testing.expect(t, hash_with_tags != hash4, "Hash should be different with tags")
}

@(test)
test_single_value_components :: proc(t: ^testing.T) {
    using ecs
    world := create_world()
    defer delete_world(world)

    Health :: distinct int

    // Create entity with Health component
    entity := add_entity(world)
    add_component(world, entity, Health(100))

    // Test querying for Health component
    result := query(world, has(Health))
    testing.expect(t, len(result) == 1, "Should have one entity with Health")

    // Test getting Health value
    health_value := get_component(world, entity, Health)
    testing.expect(t, health_value == Health(100), "Health value should be 100")

    // Test modifying Health value
    add_component(world, entity, Health(50))
    new_health := get_component(world, entity, Health)
    testing.expect(t, new_health == Health(50), "Health value should be updated to 50")

    // Test removing Health component
    remove_component(world, entity, Health)
    result_after_remove := query(world, has(Health))
    testing.expect(t, len(result_after_remove) == 0, "Should have no entities with Health after removal")
}



Gold :: distinct struct {}

benchA :: proc () {
    spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    using ecs

    benchmark_world_init :: #force_inline proc() -> (^ecs.World, time.Duration) {
        using ecs
        start_time := time.now()

        world := create_world()

        gold := add_entity(world)

        for i in 0..<1e4 {
            entity := add_entity(world)
            add_component(world, entity, Position{x = f32(i), y = f32(i * 2)})
            add_component(world, entity, Velocity{x = 1, y = 1})
            
            if i % 2 == 0 {
                add_component(world, entity, Health{value = 100})
            }
            
            if i % 3 == 0 {
                add_component(world, entity, pair(Contains{amount = i}, Gold{}))
            }
        }

        end_time := time.now()
        return world, time.diff(start_time, end_time)
    }

    benchmark_world_update :: #force_inline proc(world: ^ecs.World) -> time.Duration {
        using ecs
        start_time := time.now()
        // Query 1: Position, not Contains(Gold)
        for archetype in query(world, has(Position), not(pair(Contains, Gold))) {
            position_table := get_table(world, archetype, Position)
            for i in 0..<len(position_table) {
                position := &position_table[i]
                position.x += 1.0
                position.y += 1.0
            }
        }

        // Query 2: Position
        for archetype in query(world, has(Position)) {
            position_table := get_table(world, archetype, Position)
            for i in 0..<len(position_table) {
                position := &position_table[i]
                position.x *= 2.0
                position.y *= 2.0
            }
        }

        // Query 3: Position and Health
        for archetype in query(world, has(Position), has(Health)) {
            position_table := get_table(world, archetype, Position)
            health_table := get_table(world, archetype, Health)
            for i in 0..<len(position_table) {
                position := &position_table[i]
                health := &health_table[i]
                position.x += f32(health.value)
                position.y += f32(health.value)
            }
        }

        // Query 4: Position and Contains(Gold)
        for archetype in query(world, has(Position), pair(Contains, Gold)) {
            position_table := get_table(world, archetype, Position)
            contains_table := get_table(world, archetype, pair(Contains{}, Gold{}))
            for i in 0..<len(position_table) {
                position := &position_table[i]
                contains := &contains_table[i]
                position.x += f32(contains.amount)
                position.y += f32(contains.amount)
            }
        }

        end_time := time.now()
        return time.diff(start_time, end_time)
    }

    num_runs := 1
    total_init_duration: time.Duration
    total_update_duration: time.Duration
    
    world, init_duration := benchmark_world_init()
    for _ in 0..<num_runs {
        update_duration := benchmark_world_update(world)

        total_init_duration += init_duration
        total_update_duration += update_duration
    }
    delete_world(world)
    
    average_init_duration := total_init_duration / time.Duration(num_runs)
    average_update_duration := total_update_duration / time.Duration(num_runs)
    
    fmt.printf("Average init duration: %v\n", average_init_duration)
    fmt.printf("Average update duration: %v\n", average_update_duration)
}

benchB :: proc () {
    // spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    using ecs
    // Benchmark with 1 million entities and 7 systems
    benchmark_large_world :: proc() -> (init_duration: time.Duration, update_duration: time.Duration) {
        start_time := time.now()

        world := create_world()
        defer delete_world(world)

        // Create 1 million entities with various components
        for i in 0..<1_000_000 {
            entity := create_entity(world)
            add_component(world, entity, Position{f32(i % 1000), f32(i / 1000)})
            add_component(world, entity, Velocity{f32(i % 10), f32(i / 10)})
            
            // if i % 2 == 0 {
                add_component(world, entity, Health{100})
            // }
            // if i % 3 == 0 {
                add_component(world, entity, pair(Contains{50}, Gold{}))
            // }
            // if i % 5 == 0 {
                // add_component(world, entity, Gold{})
            // }
        }

        init_duration = time.diff(start_time, time.now())

        update_start_time := time.now()

        // System 1: Update positions based on velocity
        for archetype in query(world, has(Position), has(Velocity)) {
            position_table := get_table(world, archetype, Position)
            velocity_table := get_table(world, archetype, Velocity)
            for i in 0..<len(position_table) {
                position := &position_table[i]
                velocity := &velocity_table[i]
                position.x += velocity.x
                position.y += velocity.y
            }
        }

        // System 2: Decrease health
        for archetype in query(world, has(Health)) {
            health_table := get_table(world, archetype, Health)
            for i in 0..<len(health_table) {
                health := &health_table[i]
                health.value = max(0, health.value - 1)
            }
        }

        // System 3: Increase gold for entities with Contains
        for archetype in query(world, pair(Contains, Gold)) {
            contains_table := get_table(world, archetype, pair(Contains{}, Gold{}))
            for i in 0..<len(contains_table) {
                contains := &contains_table[i]
                contains.amount += 1
            }
        }

        // System 4: Heal entities with low health
        for archetype in query(world, has(Health)) {
            health_table := get_table(world, archetype, Health)
            for i in 0..<len(health_table) {
                health := &health_table[i]
                if health.value < 30 {
                    health.value += 5
                }
            }
        }

        // System 5: Apply velocity changes based on health
        for archetype in query(world, has(Health), has(Velocity)) {
            health_table := get_table(world, archetype, Health)
            velocity_table := get_table(world, archetype, Velocity)
            for i in 0..<len(health_table) {
                health := &health_table[i]
                velocity := &velocity_table[i]
                if health.value < 50 {
                    velocity.x *= 1.5
                    velocity.y *= 1.5
                } else {
                    velocity.x *= 0.8
                    velocity.y *= 0.8
                }
            }
        }

        // System 6: Limit position to a bounded area
        for archetype in query(world, has(Position)) {
            position_table := get_table(world, archetype, Position)
            for i in 0..<len(position_table) {
                position := &position_table[i]
                position.x = clamp(position.x, 0, 1000)
                position.y = clamp(position.y, 0, 1000)
            }
        }

        // System 7: Update Contains amount based on Position
        for archetype in query(world, has(Position), pair(Contains, Gold)) {
            position_table := get_table(world, archetype, Position)
            contains_table := get_table(world, archetype, pair(Contains{}, Gold{}))
            for i in 0..<len(position_table) {
                position := &position_table[i]
                contains := &contains_table[i]
                contains.amount = int(position.x + position.y) % 100
            }
        }

        update_duration = time.diff(update_start_time, time.now())

        return
    }

    large_init_duration, large_update_duration := benchmark_large_world()
    fmt.printf("Large world (1M entities, 7 systems) init duration: %v\n", large_init_duration)
    fmt.printf("Large world (1M entities, 7 systems) update duration: %v\n", large_update_duration)
}

benchC :: proc () {
    spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)
    using ecs
    
    benchmark_entity_creation :: proc() -> (total_duration: time.Duration, durations: map[string]time.Duration) {
        world := create_world()
        defer delete_world(world)
        
        durations = make(map[string]time.Duration)
        defer delete(durations)
        
        total_start := time.now()
        
        for i in 0..<1e6 {
            entity_start := time.now()
            entity := add_entity(world)
            durations["add_entity"] += time.diff(entity_start, time.now())
            
            pos_start := time.now()
            add_component(world, entity, Position{x = f32(i), y = f32(i * 2)})
            durations["add_Position"] += time.diff(pos_start, time.now())
            
            vel_start := time.now()
            add_component(world, entity, Velocity{x = 1, y = 1})
            durations["add_Velocity"] += time.diff(vel_start, time.now())
            
            // if i % 2 == 0 {
            //     health_start := time.now()
            //     add_component(world, entity, Health{value = 100})
            //     durations["add_Health"] += time.diff(health_start, time.now())
            // }
            
            // if i % 3 == 0 {
            //     contains_start := time.now()
            //     add_component(world, entity, Contains{amount = i})
            //     durations["add_Contains"] += time.diff(contains_start, time.now())
            // }
        }
        
        total_duration = time.diff(total_start, time.now())
        return
    }
    
    total_duration, function_durations := benchmark_entity_creation()
    fmt.printf("Total duration for entity creation and component addition (1M entities): %v\n", total_duration)
    fmt.println("Breakdown of function durations:")
    for func_name, duration in function_durations {
        fmt.printf("  %v: %v\n", func_name, duration)
    }
}

main :: proc () {
    // Initialize spall profiling
    // spall_ctx = spall.context_create("ecs_benchmark.spall")
    // defer spall.context_destroy(&spall_ctx)

    // buffer_backing := make([]u8, spall.BUFFER_DEFAULT_SIZE)
    // spall_buffer = spall.buffer_create(buffer_backing, u32(sync.current_thread_id()))
    // defer spall.buffer_destroy(&spall_ctx, &spall_buffer)

    // spall.SCOPED_EVENT(&spall_ctx, &spall_buffer, #procedure)

    // Run your benchmarks
    // benchA()
    benchB()
    // benchC()
}

// @(instrumentation_enter)
// spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
//     spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
// }

// @(instrumentation_exit)
// spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
//     spall._buffer_end(&spall_ctx, &spall_buffer)
// }