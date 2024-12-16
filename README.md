# YggECS

`YggECS` is a high-performance Entity Component System (ECS) written in Odin. It implements modern features inspired by [Flecs](https://github.com/SanderMertens/flecs), focusing on speed and simplicity. Some design principles were also used in my TypeScript ECS library [bitECS](https://github.com/NateTheGreatt/bitecs).

The name is derived from Yggdrasil, the sacred tree of Norse mythology which binds the earth, heaven, and hell together.

## Features

🔥 Blazingly fast iteration

🧬 Archetypes with cache-friendly component storage

🔍 Powerful querying with a simple, declarative API

🔗 Relational entity modeling

## Roadmap

- [ ] Observers
- [ ] Relation traversal for queries
- [ ] Query variables
- [ ] Add/removeComponent optimizations

## Usage

```odin
import ecs "./ecs"

Position :: distinct [2]f32
Velocity :: distinct [2]f32
Health :: distinct int
Contains :: struct { amount: int }
Silver :: distinct struct {}

main :: proc () {
    using ecs
    
    world := create_world()
    defer delete_world(world)

    entity := add_entity(world)
    add_component(world, entity, Position{0, 0})
    add_component(world, entity, Velocity{1, 1})
    add_component(world, entity, Health(100))

    gold := add_entity(world)
    add_component(world, item, pair(Contains{12}, gold))
    add_component(world, item, pair(Contains{58}, Silver))

    for archetype in query(world, has(Position), has(Velocity)) {
        positions := get_table(world, archetype, Position, [2]f32)
        velocities := get_table(world, archetype, Velocity, [2]f32)
        for eid,i in archetype.entities {
            positions[i] += velocities[i]
        }
    }

    entities_with_position_not_health := query(world, has(Position), not(Health))
    entities_containing_gold := query(world, pair(Contains, gold))
}
```