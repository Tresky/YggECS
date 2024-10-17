# YggECS

A simple and efficient FLECS-inspired Entity Component System (ECS) implementation in Odin.

## Usage

```odin
world := ecs.create_world()

entity := ecs.add_entity(world)
ecs.add_component(world, entity, Position{x = 0, y = 0})
ecs.add_component(world, entity, Velocity{x = 1, y = 1})

archetypes := ecs.query(world, Position, Velocity)
for archetype in archetypes {
    positions := ecs.get_table(world, archetype, Position)
    velocities := ecs.get_table(world, archetype, Velocity)
    for i := 0; i < len(positions); i += 1 {
        // Update position based on velocity
        positions[i].x += velocities[i].x
        positions[i].y += velocities[i].y
    }
}
```