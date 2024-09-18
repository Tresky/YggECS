package main

import "core:fmt"
import "core:mem"
import "core:reflect"
import "base:runtime"

// Type Definitions
EntityID     :: distinct u64
ArchetypeID  :: u64
ComponentID  :: distinct u64
ComponentSet :: map[ComponentID]bool


// Component Type Registry
ComponentTypeInfo :: struct {
    size:      int,
    type_info: ^reflect.Type_Info,
}

// Hash function for typeid
hash_of :: proc(T: typeid) -> u64 {
    h: u64 = 14695981039346656037
    id := runtime.type_info_base(type_info_of(T)).id
    data := transmute([8]byte)id
    for b in data {
        h = (h ~ u64(b)) * 1099511628211
    }
    return h
}

// Size of Type_Info
size_of_type :: proc(type_info: ^reflect.Type_Info) -> int {
    return int(runtime.type_info_base(type_info).size)
}

get_component_id :: proc(T: typeid) -> ComponentID {
    return ComponentID(hash_of(T))
}

// World struct encapsulating ECS data
World :: struct {
    component_registry:      map[ComponentID]ComponentTypeInfo,
    entity_index:            map[EntityID]EntityInfo,
    archetypes:              map[ArchetypeID]^Archetype,
    component_archetypes:    map[ComponentID]map[ArchetypeID]^Archetype,
    next_entity_id:          EntityID,
}

// Entity Info stores the location of an entity within an archetype and its version
EntityInfo :: struct {
    archetype: ^Archetype,
    row:       int,
    version:   u32,
}

// Archetype represents entities with the same component composition
Archetype :: struct {
    id:               ArchetypeID,
    component_ids:    []ComponentID,                // Sorted array of component IDs
    component_map:    map[ComponentID]int,          // Maps ComponentID to index in component_arrays
    entities:         [dynamic]EntityID,            // Entity IDs
    component_arrays: [dynamic][dynamic]byte,       // Arrays of component data
    component_types:  [dynamic]^reflect.Type_Info,  // Type info for each component array
    tag_set:          ComponentSet,                 // Set of tags
    disabled_set:     ComponentSet,                 // Set of disabled components
    relationships:    map[ComponentID][]Relationship, // Relationships
    add_edges:        map[ComponentID]^Archetype,   // Archetype transitions
    remove_edges:     map[ComponentID]^Archetype,   // Archetype transitions
}

// Corrected register_component function
register_component :: proc(world: ^World, T: typeid) -> ComponentID {
    id := get_component_id(T)
    type_info := type_info_of(T)
    world.component_registry[id] = ComponentTypeInfo{
        size      = size_of_type(type_info),
        type_info = type_info,
    }
    return id
}

// Create a new entity
create_entity :: proc(world: ^World) -> EntityID {
    entity := world.next_entity_id
    world.next_entity_id = EntityID(u64(world.next_entity_id) + 1)

    // Initialize EntityInfo
    world.entity_index[entity] = EntityInfo{
        archetype = nil,
        row       = -1,
        version   = 1,
    }
    return entity
}

// Delete an entity
delete_entity :: proc(world: ^World, entity: EntityID) {
    info, ok := world.entity_index[entity]
    if !ok || info.archetype == nil {
        return // Entity does not exist
    }

    archetype := info.archetype
    row := info.row

    // Remove the entity from the archetype
    last_index := len(archetype.entities) - 1
    last_entity := archetype.entities[last_index]

    // Swap
    archetype.entities[row] = last_entity
    // Pop
    pop(&archetype.entities)

    // Update component arrays
    for idx := 0; idx < len(archetype.component_arrays); idx += 1 {
        array := &archetype.component_arrays[idx]
        swap_and_pop(array, row, last_index, size_of_type(archetype.component_types[idx]))
    }

    // Update entity index for the moved entity
    if entity_info, exists := world.entity_index[last_entity]; exists {
        entity_info.row = row
        world.entity_index[last_entity] = entity_info
    }

    // Remove the entity from the entity index
    delete_key(&world.entity_index, entity)
}

swap_and_pop :: proc(array: ^[dynamic]byte, i: int, last_index: int, size: int) {
    if len(array^) == 0 || i >= len(array^) || last_index >= len(array^) {
        return
    }
    offset_i    := i * size
    offset_last := last_index * size
    mem.copy(&array^[offset_i], &array^[offset_last], size)
    resize(array, offset_last)
}

// Add a component to an entity
add_component :: proc(world: ^World, entity: EntityID, component: $T) {
    fmt.printf("Adding component to entity: %v\n", entity)
    component_id := get_component_id(T)
    component_info, ok := world.component_registry[component_id]
    if !ok {
        // Component type not registered
        fmt.printf("Component type not registered: %v\n", component_id)
        return
    }

    info := world.entity_index[entity]

    new_component_ids: []ComponentID
    tag_set: ComponentSet
    if info.archetype != nil {
        // Entity is in an archetype
        old_archetype := info.archetype
        new_component_ids = make([]ComponentID, len(old_archetype.component_ids) + 1)
        copy(new_component_ids, old_archetype.component_ids)
        new_component_ids[len(old_archetype.component_ids)] = component_id
        sort_component_ids(new_component_ids)
        tag_set = old_archetype.tag_set
    } else {
        // Entity is not in any archetype yet
        new_component_ids = []ComponentID{component_id}
        tag_set = make(ComponentSet)
    }

    new_archetype := get_or_create_archetype(world, new_component_ids, tag_set)

    fmt.printf("Moving entity %v to new archetype\n", entity)
    // Move entity to new archetype
    move_entity(world, entity, info, info.archetype, new_archetype)

    // Add component data
    index := world.entity_index[entity].row
    local_component := component
    fmt.printf("Adding component data for entity %v at index %v\n", entity, index)
    add_component_data(new_archetype, component_id, rawptr(&local_component), index, T)
    fmt.printf("Component added successfully to entity: %v\n", entity)
}

// Remove a component from an entity
remove_component :: proc(world: ^World, entity: EntityID, T: typeid) {
    component_id := get_component_id(T)
    info := world.entity_index[entity]

    old_archetype := info.archetype
    if old_archetype == nil {
        return // Entity does not have this component
    }

    // Check if the component exists in the archetype
    _, exists := old_archetype.component_map[component_id]
    if !exists {
        return // Component not present
    }

    // Create new component ID set without the component
    new_component_ids := remove_component_id(old_archetype.component_ids, component_id)
    new_archetype := get_or_create_archetype(world, new_component_ids, old_archetype.tag_set)

    // Move entity to new archetype
    move_entity(world, entity, info, old_archetype, new_archetype)
}

// Disable a component on an entity
disable_component :: proc(world: ^World, entity: EntityID, T: typeid) {
    component_id := get_component_id(T)
    info := world.entity_index[entity]
    archetype := info.archetype
    if archetype == nil {
        return
    }
    archetype.disabled_set[component_id] = true
}

// Enable a component on an entity
enable_component :: proc(world: ^World, entity: EntityID, T: typeid) {
    component_id := get_component_id(T)
    info := world.entity_index[entity]
    archetype := info.archetype
    if archetype == nil {
        return
    }
    delete_key(&archetype.disabled_set, component_id)
}

// Add a tag to an entity
add_tag :: proc(world: ^World, entity: EntityID, T: typeid) {
    component_id := get_component_id(T)
    info := world.entity_index[entity]

    old_archetype := info.archetype
    if old_archetype == nil {
        old_archetype = get_or_create_archetype(world, []ComponentID{}, make(map[ComponentID]bool))
    }

    // Clone the tag_set to avoid shared references
    new_tag_set := make(map[ComponentID]bool)
    for k, v in old_archetype.tag_set {
        new_tag_set[k] = v
    }
    new_tag_set[component_id] = true

    // Since tags don't have data, we don't need to update component arrays
    new_archetype := get_or_create_archetype(world, old_archetype.component_ids, new_tag_set)

    // Move entity to new archetype
    move_entity(world, entity, info, old_archetype, new_archetype)
}

// Add component data to an archetype
add_component_data :: proc(archetype: ^Archetype, component_id: ComponentID, component: rawptr, index: int, T: typeid) {
    comp_index, ok := archetype.component_map[component_id]
    if !ok {
        return
    }

    array := &archetype.component_arrays[comp_index]
    type_info := archetype.component_types[comp_index]
    size := size_of_type(type_info)

    current_length := len(array^) / size
    if current_length <= index {
        new_length := (index + 1) * size
        new_arr := make([dynamic]byte, new_length)
        mem.copy(&new_arr[0], &array^[0], len(array^))
        array^ = new_arr
    }

    offset := index * size
    mem.copy(&array^[offset], component, size)
}
move_entity :: proc(world: ^World, entity: EntityID, info: EntityInfo, old_archetype: ^Archetype, new_archetype: ^Archetype) {
    // Remove from old archetype if necessary
    if old_archetype != nil && info.row >= 0 {
        old_row := info.row
        last_index := len(old_archetype.entities) - 1
        
        if old_row != last_index {
            // Swap with the last entity
            last_entity := old_archetype.entities[last_index]
            old_archetype.entities[old_row] = last_entity
            
            // Update component arrays
            for idx in 0..<len(old_archetype.component_arrays) {
                array := &old_archetype.component_arrays[idx]
                size := size_of_type(old_archetype.component_types[idx])
                swap_and_pop(array, old_row, last_index, size)
            }
            
            // Update entity index for the moved entity
            if entity_info, exists := world.entity_index[last_entity]; exists {
                entity_info.row = old_row
                world.entity_index[last_entity] = entity_info
            }
        }
        
        // Remove the last entity
        pop(&old_archetype.entities)
    }

    // Add to new archetype
    new_row := len(new_archetype.entities)
    append(&new_archetype.entities, entity)

    // Update entity index
    world.entity_index[entity] = EntityInfo{
        archetype = new_archetype,
        row       = new_row,
        version   = info.version,
    }

    // Resize and copy shared component data
    for component_id, new_comp_index in new_archetype.component_map {
        new_array := &new_archetype.component_arrays[new_comp_index]
        type_info := new_archetype.component_types[new_comp_index]
        size := size_of_type(type_info)

        // Ensure new_array is big enough
        new_array^ = resize_array(new_array^, new_row + 1, size)

        if old_archetype != nil && info.row >= 0 {
            if old_comp_index, exists := old_archetype.component_map[component_id]; exists {
                // Copy component data from old to new
                old_array := old_archetype.component_arrays[old_comp_index]
                old_offset := info.row * size
                new_offset := new_row * size
                mem.copy(&new_array^[new_offset], &old_array[old_offset], size)
            }
        }
    }
}


resize_array :: proc(array: [dynamic]byte, new_elements: int, element_size: int) -> [dynamic]byte {
    new_size := new_elements * element_size
    if new_size == 0 {
        return make([dynamic]byte, 0)
    }
    if len(array) < new_size {
        new_array := make([dynamic]byte, new_size)
        if len(array) > 0 {
            mem.copy(&new_array[0], &array[0], min(len(array), new_size))
        }
        return new_array
    }
    // If the new size is smaller, we need to create a new dynamic array with the reduced size
    if new_size < len(array) {
        new_array := make([dynamic]byte, new_size)
        mem.copy(&new_array[0], &array[0], new_size)
        return new_array
    }
    return array
}


get_or_create_archetype :: proc(world: ^World, component_ids: []ComponentID, tag_set: map[ComponentID]bool) -> ^Archetype {
    archetype_id := hash_archetype(component_ids, tag_set)
    archetype, exists := world.archetypes[archetype_id]
    if exists {
        fmt.printf("Archetype %v already exists.\n", archetype_id)
        return archetype
    }

    fmt.printf("Creating new archetype %v with components: %v and tags: %v\n", archetype_id, component_ids, tag_set)

    // Create new archetype
    archetype = new(Archetype)
    archetype.id = archetype_id
    archetype.component_ids = component_ids
    archetype.component_map = make(map[ComponentID]int)
    archetype.entities = make([dynamic]EntityID)
    archetype.component_arrays = make([dynamic][dynamic]byte)
    archetype.component_types = make([dynamic]^reflect.Type_Info)
    archetype.tag_set = tag_set
    archetype.disabled_set = make(map[ComponentID]bool)
    archetype.relationships = make(map[ComponentID][]Relationship)
    archetype.add_edges = make(map[ComponentID]^Archetype)
    archetype.remove_edges = make(map[ComponentID]^Archetype)

    // Initialize component arrays
    for cid in component_ids {
        component_info := world.component_registry[cid]
        if component_info.size > 0 {
            // Only allocate storage for components with data
            new_array := make([dynamic]byte)
            append(&archetype.component_arrays, new_array)
            append(&archetype.component_types, component_info.type_info)
            archetype.component_map[cid] = len(archetype.component_arrays) - 1
        } else {
            // For tags, no component array is needed
            archetype.tag_set[cid] = true
        }
    }

    // Add to archetypes map
    world.archetypes[archetype_id] = archetype

    // Update component archetypes
    for cid in component_ids {
        comp_map, ok := world.component_archetypes[cid]
        if !ok {
            comp_map = make(map[ArchetypeID]^Archetype)
            world.component_archetypes[cid] = comp_map
        }
        comp_map[archetype_id] = archetype
    }

    return archetype
}

sort_component_ids :: proc(ids: []ComponentID) {
    // Simple insertion sort for small arrays
    for i := 1; i < len(ids); i += 1 {
        key := ids[i]
        j := i - 1
        for j >= 0 && ids[j] > key {
            ids[j+1] = ids[j]
            j -= 1
        }
        ids[j+1] = key
    }
}

// Helper to remove a component ID from a slice
remove_component_id :: proc(ids: []ComponentID, cid: ComponentID) -> []ComponentID {
    for i, id in ids {
        if u64(id) == u64(cid) {
            new_ids := make([]ComponentID, len(ids) - 1)
            copy(new_ids, ids[:i])
            copy(new_ids[i:], ids[i+1:])
            return new_ids
        }
    }
    return ids
}

hash_archetype :: proc(component_ids: []ComponentID, tag_set: map[ComponentID]bool) -> ArchetypeID {
    h := u64(14695981039346656037) // FNV-1a 64-bit offset basis

    // Hash component_ids
    for id in component_ids {
        h = (h ~ u64(id)) * 1099511628211
    }

    // Collect tag_set ComponentIDs into a dynamic array
    sorted_tags := make([dynamic]ComponentID)
    defer delete(sorted_tags)

    for id in tag_set {
        append(&sorted_tags, id)
    }
    sort_component_ids(sorted_tags[:])

    // Hash sorted tag_set
    for id in sorted_tags {
        h = (h ~ u64(id)) * 1099511628211
    }

    return ArchetypeID(h)
}

query :: proc(world: ^World, T: typeid) -> []EntityID {
    cid := get_component_id(T)
    archetype_map, ok := world.component_archetypes[cid]
    if !ok {
        return []EntityID{}
    }

    total_entities := 0
    for _, archetype in archetype_map {
        total_entities += len(archetype.entities)
    }

    result := make([]EntityID, total_entities)
    index := 0
    for _, archetype in archetype_map {
        for entity in archetype.entities {
            result[index] = entity
            index += 1
        }
    }

    return result
}

get_component :: proc(world: ^World, $T: typeid, info: EntityInfo) -> T {
    cid := get_component_id(T)
    archetype := info.archetype
    if archetype == nil {
        return T{}
    }
    comp_index, ok := archetype.component_map[cid]
    if !ok {
        return T{}
    }
    array := archetype.component_arrays[comp_index]
    row := info.row  // Fixed typo here
    type_info := archetype.component_types[comp_index]
    size := size_of_type(type_info)

    offset := row * size  // Fixed typo here
    if offset + size > len(array) {
        return T{}
    }
    return (^T)(&array[offset])^
}

create_world :: proc() -> ^World {
    world := new(World)
    world.component_registry = make(map[ComponentID]ComponentTypeInfo)
    world.entity_index = make(map[EntityID]EntityInfo)
    world.archetypes = make(map[ArchetypeID]^Archetype)
    world.component_archetypes = make(map[ComponentID]map[ArchetypeID]^Archetype)
    world.next_entity_id = EntityID(1)
    return world
}

// Component Definitions
Position :: struct {
    x, y: f32
}

Velocity :: struct {
    dx, dy: f32
}

Mass :: struct {
    value: f32
}

// Zero-Sized Type (Tag)
Npc :: struct {}

// Relationship Component
Likes :: struct {
    target: EntityID
}

// Relationship type definition
Relationship :: struct {
    target: EntityID
}

main :: proc() {
    // Initialize the ECS
    world := create_world()

    // Register Components
    POSITION_ID := register_component(world, Position)
    VELOCITY_ID := register_component(world, Velocity)
    MASS_ID     := register_component(world, Mass)
    NPC_ID      := register_component(world, Npc)
    LIKES_ID    := register_component(world, Likes)

    // Create an entity with Position and Velocity
    e1 := create_entity(world)
    add_component(world, e1, Position{x = 10, y = 20})
    add_component(world, e1, Velocity{dx = 5, dy = 5})

    // Create another entity with Position
    e2 := create_entity(world)
    add_component(world, e2, Position{x = 15, y = 25})

    // Add Mass to e1
    add_component(world, e1, Mass{value = 5.0})

    // Remove Velocity from e1
    remove_component(world, e1, Velocity)

    // Disable Mass on e1
    disable_component(world, e1, Mass)

    // Enable Mass on e1
    enable_component(world, e1, Mass)

    // Add a tag to e1
    add_tag(world, e1, Npc)

    // Add a relationship (Likes) to e1
    e3 := create_entity(world)
    add_component(world, e1, Likes{target = e3})

    // Query entities with Position
    fmt.println("Entities with Position:")
    position_entities := query(world, Position)
    for entity in position_entities {
        info := world.entity_index[entity]
        position := get_component(world, Position, info)
        fmt.printf("Entity %v: Position(%f, %f)\n", entity, position.x, position.y)
    }
    fmt.printf("Total entities with Position: %d\n", len(position_entities))

    // Query entities with Mass (including disabled components)
    fmt.println("Entities with Mass:")
    mass_entities := query(world, Mass)
    for entity in mass_entities {
        info := world.entity_index[entity]
        mass := get_component(world, Mass, info)
        fmt.printf("Entity %v: Mass(%f)\n", entity, mass.value)
    }
    fmt.printf("Total entities with Mass: %d\n", len(mass_entities))

    // Delete e1
    delete_entity(world, e1)

    // Recycle e1
    e4 := create_entity(world)
    add_component(world, e4, Position{x = 0, y = 0})
    fmt.printf("Recycled entity ID: %v\n", e4)

}