package ecs

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:fmt"

// Type Definitions
EntityID :: distinct u64
ArchetypeID :: u64
ComponentID :: EntityID
ComponentSet :: map[ComponentID]bool

// Errors
Error :: enum {
	None,
	EntityNotFound,
	ComponentNotFound,
	ArchetypeNotFound,
	ComponentDataOutOfBounds,
	InvalidComponentID,
	EntityAlreadyExists,
	ComponentAlreadyExists,
	ComponentDisabled,
	OperationFailed,
}

Result :: union($T: typeid) {
	T,
	Error,
}

// Component Type Registry
ComponentTypeInfo :: struct {
	size:      int,
	type_info: ^reflect.Type_Info,
}

// Size of Type_Info
size_of_type :: proc(type_info: ^reflect.Type_Info) -> int {
	return int(runtime.type_info_base(type_info).size)
}

get_component_id :: proc(world: ^World, T: typeid) -> ComponentID {
	type_info := type_info_of(T)
	return world.component_ids[type_info.id]
}

// World struct encapsulating ECS data
World :: struct {
	component_registry:   map[ComponentID]ComponentTypeInfo,
	component_info:       map[ComponentTypeInfo]ComponentID,
	component_ids:        map[typeid]ComponentID,
	entity_index:         map[EntityID]EntityInfo,
	archetypes:           map[ArchetypeID]^Archetype,
	component_archetypes: map[ComponentID]map[ArchetypeID]^Archetype,
	next_entity_id:       EntityID,
	queries:              [dynamic]^Query,
}

// Entity Info stores the location of an entity within an archetype and its version
// TODO: store version in upper 16 bits of entity ID
// TODO: if entity ID is a Pair: store relationship target in lower 16 bits and relation id in upper 16 bits
Pair :: struct {
	id: ComponentID,
	target: EntityID,
	relation: EntityID,
}

EntityInfo :: struct {
	archetype: ^Archetype,
	row:       int,
	version:   u32,
	pair: Pair,
}

Query :: struct {
	component_ids: []ComponentID,
	archetypes:    [dynamic]^Archetype,
}
Archetype :: struct {
	id:               ArchetypeID,
	component_ids:    []ComponentID,
	component_types:  map[ComponentID]^reflect.Type_Info,
	entities:         [dynamic]EntityID,
	tables:           map[ComponentID][dynamic]byte,
	tag_set:          ComponentSet,
	disabled_set:     ComponentSet,
	matching_queries: [dynamic]^Query,
	// TODO
	add_edges:        map[ComponentID]^Archetype,
	remove_edges:     map[ComponentID]^Archetype,
}

// Pretty print an archetype
print_archetype :: proc(archetype: ^Archetype) {
    fmt.printf("┌───────────────────────────────────────────────────────────────┐\n")
    fmt.printf("│ Archetype ID: %d\n", archetype.id)
    fmt.printf("├───────────────────────────────────────────────────────────────┤\n")
    fmt.printf("│ Components:\n")
    for component_id in archetype.component_ids {
        fmt.printf("│   %d\n", component_id)
    }
    fmt.printf("├───────────────────────────────────────────────────────────────┤\n")
    fmt.printf("│ Tags:\n")
    for tag in archetype.tag_set {
        fmt.printf("│   %d\n", tag)
    }
    fmt.printf("├───────────────────────────────────────────────────────────────┤\n")
    fmt.printf("│ Disabled Components:\n")
    for disabled in archetype.disabled_set {
        fmt.printf("│   %d\n", disabled)
    }
    fmt.printf("├───────────────────────────────────────────────────────────────┤\n")
    fmt.printf("│ Entity Count: %d\n", len(archetype.entities))
    fmt.printf("├───────────────────────────────────────────────────────────────┤\n")
    fmt.printf("│ Tables:\n")
    for component_id, table in archetype.tables {
        fmt.printf("│   Component %d: %d bytes\n", component_id, len(table))
    }
    fmt.printf("├───────────────────────────────────────────────────────────────┤\n")
    fmt.printf("│ Matching Queries:\n")
    for query in archetype.matching_queries {
        fmt.printf("│   Query with %d components\n", len(query.component_ids))
    }
    fmt.printf("└───────────────────────────────────────────────────────────────┘\n")
}


create_world :: proc() -> ^World {
	world := new(World)
	world.component_registry = make(map[ComponentID]ComponentTypeInfo)
	world.entity_index = make(map[EntityID]EntityInfo)
	world.archetypes = make(map[ArchetypeID]^Archetype)
	world.component_archetypes = make(map[ComponentID]map[ArchetypeID]^Archetype)
	world.next_entity_id = EntityID(1)
	world.queries = make([dynamic]^Query)
	return world
}

// Add this function to clean up the World struct
delete_world :: proc(world: ^World) {
	if world == nil {
		return
	}

	for _, archetype in world.archetypes {
		destroy_archetype(archetype)
	}
	delete(world.component_registry)
	delete(world.entity_index)
	delete(world.archetypes)
	for _, comp_map in world.component_archetypes {
		delete(comp_map)
	}
	delete(world.component_archetypes)
	free(world)
}


register_component :: proc(world: ^World, $T: typeid) -> ComponentID {
	id := add_entity(world)
	type_info := type_info_of(T)
	info := ComponentTypeInfo {
		size      = size_of_type(type_info),
		type_info = type_info,
	}
	world.component_registry[id] = info
	world.component_info[info] = id
	world.component_ids[type_info.id] = id
	return id
}

// Create a new entity
add_entity :: proc(world: ^World) -> EntityID {
	entity := world.next_entity_id
	world.next_entity_id = world.next_entity_id + 1

	// Initialize EntityInfo
	world.entity_index[entity] = EntityInfo {
		archetype = nil,
		row       = -1,
		version   = 0,
	}
	return entity
}

create_entity :: add_entity

// Remove an entity from the world
remove_entity :: proc(world: ^World, entity: EntityID) {
    info, ok := world.entity_index[entity]
    if !ok || info.archetype == nil {
        return // Entity does not exist or has already been removed
    }

    archetype := info.archetype
    row := info.row
    last_row := len(archetype.entities) - 1

    // Swap the entity to be removed with the last entity in the archetype
    if row != last_row {
        last_entity := archetype.entities[last_row]
        archetype.entities[row] = last_entity

        // Update all component tables
        for component_id, &component_array in &archetype.tables {
            if component_id in archetype.tag_set {
                continue // Skip tags as they don't have data
            }
            
            type_info := archetype.component_types[component_id]
            size := size_of_type(type_info)
            
            // Move the last element's data to the removed entity's position
            mem.copy(&component_array[row * size], &component_array[last_row * size], size)
        }

        // Update the moved entity's index
        if moved_info, exists := &world.entity_index[last_entity]; exists {
            moved_info.row = row
        }
    }

    // Remove the last entity (which is now the entity we want to remove)
    pop(&archetype.entities)

    // Resize all component arrays
    for component_id, &component_array in &archetype.tables {
        if component_id in archetype.tag_set {
            continue // Skip tags as they don't have data
        }
        
        type_info := archetype.component_types[component_id]
        size := size_of_type(type_info)
        
        resize(&component_array, len(archetype.entities) * size)
    }

    // Clear the entity's info
    delete_key(&world.entity_index, entity)

    // If the archetype is now empty, remove it from the world
    if len(archetype.entities) == 0 {
        delete_key(&world.archetypes, archetype.id)
        for component_id in archetype.component_ids {
            if component_archetypes, ok := &world.component_archetypes[component_id]; ok {
                delete_key(component_archetypes, archetype.id)
            }
        }
        destroy_archetype(archetype)
    }
}

delete_entity :: remove_entity

entity_exists :: proc(world: ^World, entity: EntityID) -> bool {
	info, ok := world.entity_index[entity]
	return ok && info.archetype != nil
}

entity_alive :: entity_exists

has_component :: proc(world: ^World, entity: EntityID, $T: typeid) -> bool {
	info, exists := world.entity_index[entity]
	if !exists || info.archetype == nil {
		return false
	}

	cid := get_component_id(world, T)
	return slice.contains(info.archetype.component_ids, cid)
}
// Add a component to an entity
add_component :: proc(world: ^World, entity: EntityID, component: $T) {
	_, ok := world.component_registry[get_component_id(world, T)]
	if !ok {
		register_component(world, T)
	}
	component_id := get_component_id(world, T)

    info := world.entity_index[entity]
    old_archetype := info.archetype
	new_archetype : ^Archetype

    // If the entity doesn't have an archetype yet, create a new one
    if old_archetype == nil {
        new_component_ids := []ComponentID{component_id}
        tag_set := make(ComponentSet)
        if size_of(T) == 0 {
            tag_set[component_id] = true
        }
        new_archetype = get_or_create_archetype(world, new_component_ids, tag_set)
        move_entity(world, entity, info, nil, new_archetype)
    } else {
        // Get the next archetype from the graph
        new_archetype, ok = old_archetype.add_edges[component_id]
        if !ok {
            // If the edge doesn't exist, create a new archetype
            new_component_ids := make([]ComponentID, len(old_archetype.component_ids) + 1)
            copy(new_component_ids, old_archetype.component_ids)
            new_component_ids[len(old_archetype.component_ids)] = component_id
            sort_component_ids(new_component_ids)
            
            tag_set := make(ComponentSet)
            for k, v in old_archetype.tag_set {
                tag_set[k] = v
            }
            if size_of(T) == 0 {
                tag_set[component_id] = true
            }
            
            new_archetype = get_or_create_archetype(world, new_component_ids, tag_set)
            old_archetype.add_edges[component_id] = new_archetype
        }
        
        move_entity(world, entity, info, old_archetype, new_archetype)
    }

    // Add component data if it's not a tag
    if size_of(T) > 0 {
        index := world.entity_index[entity].row
        local_component := component
        add_component_data(new_archetype, component_id, rawptr(&local_component), index, T)
    }
}

add_component_data :: proc(
    archetype: ^Archetype,
    component_id: ComponentID,
    component: rawptr,
    index: int,
    $T: typeid,
) {
    table, ok := &archetype.tables[component_id]
    if !ok {
        return
    }
    size := size_of(T)

    if size == 0 {
        return  // Skip tags as they don't have data
    }

    if len(table^) < (index + 1) * size {
        resize(table, (index + 1) * size)
    }

    offset := index * size
    mem.copy(&table^[offset], component, size)
}

remove_component_id :: proc(ids: []ComponentID, cid: ComponentID) -> []ComponentID {
	new_ids := make([dynamic]ComponentID, 0, len(ids) - 1)
	for id in ids {
		if u64(id) != u64(cid) {
			append(&new_ids, id)
		}
	}
	return new_ids[:] 
}
remove_component :: proc(world: ^World, entity: EntityID, $T: typeid) {
	component_id := get_component_id(world, T)
	info := world.entity_index[entity]

	old_archetype := info.archetype
	if old_archetype == nil {
		return // Entity does not have this component
	}

	// Check if the component exists in the archetype
	if !slice.contains(old_archetype.component_ids, component_id) {
		return // Component not present
	}

	// Use the remove_edges graph to get the next archetype
	new_archetype, ok := old_archetype.remove_edges[component_id]
	if !ok {
		// If the edge doesn't exist, create a new archetype
		new_component_ids := remove_component_id(old_archetype.component_ids, component_id)
		defer delete(new_component_ids)

		new_tag_set := make(map[ComponentID]bool)
		for k, v in old_archetype.tag_set {
			if k != component_id {
				new_tag_set[k] = v
			}
		}

		new_archetype = get_or_create_archetype(world, new_component_ids, new_tag_set)
		old_archetype.remove_edges[component_id] = new_archetype
	}

	// Move entity to new archetype
	move_entity(world, entity, info, old_archetype, new_archetype)
}


disable_component :: proc(world: ^World, entity: EntityID, $T: typeid) {
	component_id := get_component_id(world, T)
	info := world.entity_index[entity]
	archetype := info.archetype
	if archetype == nil {
		return
	}
	archetype.disabled_set[component_id] = true
}

enable_component :: proc(world: ^World, entity: EntityID, $T: typeid) {
	component_id := get_component_id(world, T)
	info := world.entity_index[entity]
	archetype := info.archetype
	if archetype == nil {
		return
	}
	delete_key(&archetype.disabled_set, component_id)
}

move_entity :: proc(
	world: ^World,
	entity: EntityID,
	info: EntityInfo,
	old_archetype: ^Archetype,
	new_archetype: ^Archetype,
) {
	// Add to new archetype
	new_row := len(new_archetype.entities)
	append(&new_archetype.entities, entity)

	// Update entity index
	world.entity_index[entity] = EntityInfo {
		archetype = new_archetype,
		row       = new_row,
		version   = info.version,
	}

	// Resize and copy shared component data
	for component_id in new_archetype.component_ids {
		if component_id in new_archetype.tag_set {
			continue  // Tags don't have data, so we skip them
		}

		new_table, ok := &new_archetype.tables[component_id]
		if !ok {
			new_table^ = make([dynamic]byte)
			new_archetype.tables[component_id] = new_table^
		}
		type_info := new_archetype.component_types[component_id]
		size := size_of_type(type_info)

		// Ensure new_table is big enough
		if len(new_table^) < (new_row + 1) * size {
			resize(new_table, (new_row + 1) * size)
		}

		new_offset := new_row * size

		if old_archetype != nil {
			if old_table, exists := old_archetype.tables[component_id]; exists && len(old_table) > 0 {
				// Copy component data from old to new
				old_offset := info.row * size
				if old_offset < len(old_table) && new_offset < len(new_table^) {
					mem.copy(&new_table[new_offset], &old_table[old_offset], size)
				}
			} else {
				// Initialize new component data to zero
				mem.zero(&new_table[new_offset], size)
			}
		} else {
			// Initialize new component data to zero
			mem.zero(&new_table[new_offset], size)
		}
	}

	// Remove from old archetype if necessary
	if old_archetype != nil && info.row >= 0 {
		old_row := info.row
		last_index := len(old_archetype.entities) - 1

		if old_row != last_index {
			// Swap with the last entity
			last_entity := old_archetype.entities[last_index]
			old_archetype.entities[old_row] = last_entity

			// Update component tables
			for component_id, &table in &old_archetype.tables {
				if component_id in old_archetype.tag_set {
					continue  // Skip tags as they don't have data
				}
				
				type_info := old_archetype.component_types[component_id]
				size := size_of_type(type_info)
				
				// Move last element to the removed position
				mem.copy(&table[old_row * size], &table[last_index * size], size)
				
				// Shrink the table
				resize(&table, (last_index) * size)
			}

			// Update entity index for the moved entity
			if entity_info, exists := &world.entity_index[last_entity]; exists {
				entity_info.row = old_row
			}
		} else {
			// If it's the last entity, just remove it from all tables
			for component_id, &table in &old_archetype.tables {
				if component_id in old_archetype.tag_set {
					continue  // Skip tags as they don't have data
				}
				
				type_info := old_archetype.component_types[component_id]
				size := size_of_type(type_info)
				
				// Shrink the table
				resize(&table, (last_index) * size)
			}
		}

		// Remove the last entity
		pop(&old_archetype.entities)

	}

	// If the old archetype exists and has 0 entities, remove it
	if old_archetype != nil && len(old_archetype.entities) == 0 {
		delete_key(&world.archetypes, old_archetype.id)
		destroy_archetype(old_archetype)
		// TODO: remove from queries
	}
}

get_or_create_archetype :: proc(
	world: ^World,
	component_ids: []ComponentID,
	tag_set: map[ComponentID]bool,
) -> ^Archetype {
	archetype_id := hash_archetype(component_ids, tag_set)
	archetype, exists := world.archetypes[archetype_id]
	if exists {
		return archetype
	}

	// Create new archetype
	archetype = new(Archetype)
	archetype.id = archetype_id
	archetype.component_ids = slice.clone(component_ids)
	archetype.entities = make([dynamic]EntityID)
	archetype.tables = make(map[ComponentID][dynamic]byte)
	archetype.component_types = make(map[EntityID]^reflect.Type_Info)
	archetype.tag_set = make(map[ComponentID]bool)
	for k, v in tag_set {
		archetype.tag_set[k] = v
	}
	archetype.disabled_set = make(map[ComponentID]bool)
	archetype.add_edges = make(map[ComponentID]^Archetype)
	archetype.remove_edges = make(map[ComponentID]^Archetype)
	// Initialize component arrays and update component archetypes
	for cid in component_ids {
		component_info := world.component_registry[cid]
		if component_info.size > 0 {
			// Only allocate storage for components with data
			new_table := make([dynamic]byte)
			archetype.tables[cid] = new_table
			archetype.component_types[cid] = component_info.type_info
		} else {
			// For tags, no component array is needed
			archetype.tag_set[cid] = true
		}
	}

	// Add to archetypes map
	world.archetypes[archetype_id] = archetype

	return archetype
}

destroy_archetype :: proc(archetype: ^Archetype) {
	if archetype == nil {
		return
	}

	delete(archetype.component_ids)
	delete(archetype.entities)
	for _, array in archetype.tables {
		delete(array)
	}
	delete(archetype.tables)
	delete(archetype.component_types)
	delete(archetype.tag_set)
	delete(archetype.disabled_set)
	delete(archetype.add_edges)
	delete(archetype.remove_edges)
	free(archetype)
}

sort_component_ids :: proc(ids: []ComponentID) {
	// Simple insertion sort for small arrays
	for i := 1; i < len(ids); i += 1 {
		key := ids[i]
		j := i - 1
		for j >= 0 && ids[j] > key {
			ids[j + 1] = ids[j]
			j -= 1
		}
		ids[j + 1] = key
	}
}

hash_archetype :: proc(
	component_ids: []ComponentID,
	tag_set: map[ComponentID]bool,
) -> ArchetypeID {
	h := u64(14695981039346656037) // FNV-1a 64-bit offset basis

	// Sort and hash component_ids
	sorted_component_ids := make([]ComponentID, len(component_ids))
	defer delete(sorted_component_ids)
	copy(sorted_component_ids, component_ids)
	sort_component_ids(sorted_component_ids)
	for id in sorted_component_ids {
		h = (h ~ u64(id)) * 1099511628211
	}

	// Collect and sort tag_set ComponentIDs
	sorted_tags := make([dynamic]ComponentID, len(tag_set))
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

get_component :: proc(world: ^World, entity: EntityID, $T: typeid) -> ^T {
	info := world.entity_index[entity]
	cid := get_component_id(world, T)
	archetype := info.archetype
	array, ok := archetype.tables[cid]
	if !ok {
		return nil
	}
	row := info.row
	type_info := archetype.component_types[cid]
	size := size_of_type(type_info)

	offset := row * size
	return (^T)(&array[offset])
}

get_table :: proc {
	get_table_same,
	get_table_cast,
}

get_table_same :: proc(world: ^World, archetype: ^Archetype, $Component: typeid) -> []Component {
	component_id := get_component_id(world, Component)
	table, ok := archetype.tables[component_id]
	if !ok {
		return nil
	}

	component_size := size_of(Component)
	num_components := len(table) / component_size
	return (cast(^[dynamic]Component)(&table))[:num_components]
}

get_table_cast :: proc(
	world: ^World,
	archetype: ^Archetype,
	$Component: typeid,
	$CastTo: typeid,
) -> []CastTo {
	component_id := get_component_id(world, Component)
	table, ok := archetype.tables[component_id]
	if !ok {
		return nil
	}

	component_size := size_of(CastTo)
	num_components := len(table) / component_size
	return (cast(^[dynamic]CastTo)(&table))[:num_components]
}

get_table_row :: proc(world: ^World, entity_id: EntityID) -> int {
    if info, ok := world.entity_index[entity_id]; ok {
        return info.row
    }
    return -1
}

query :: proc(world: ^World, component_types: ..typeid) -> []^Archetype {
	if len(component_types) == 0 {
		return nil
	}

	component_ids := make([]ComponentID, len(component_types))
	defer delete(component_ids)

	for i := 0; i < len(component_types); i += 1 {
		component_id := get_component_id(world, component_types[i])
		if component_id == 0 {
			// Component isn't registered, return empty slice
			return []^Archetype{}
		}
		component_ids[i] = component_id
	}

	result := make([dynamic]^Archetype, context.temp_allocator)
	for _, archetype in world.archetypes {
		all_components_present := true
		for id in component_ids {
			if !slice.contains(archetype.component_ids, id) {
				all_components_present = false
				break
			}
		}
		if all_components_present {
			append(&result, archetype)
		}
	}

	return result[:]
}

