package main

import "core:fmt"

EntityIndex :: struct {
    alive_count:    u64,
    dense:          [dynamic]u64,
    sparse:         []u64,
    max_id:         u64,
    versioning:     bool,
    version_bits:   u64,
    entity_mask:    u64,
    version_shift:  u64,
    version_mask:   u64,
}

create_entity_index :: proc(versioning := false, version_bits: u64 = 16) -> EntityIndex {
    entity_bits := 64 - version_bits
    entity_mask := u64((1 << entity_bits) - 1)
    version_shift := entity_bits
    version_mask := u64(((1 << version_bits) - 1) << version_shift)

    initial_sparse_size := 16
    sparse := make([]u64, initial_sparse_size)
    for i in 0..<initial_sparse_size {
        sparse[i] = 0xFFFFFFFFFFFFFFFF
    }

    return EntityIndex{
        alive_count    = 0,
        dense          = make([dynamic]u64, 0, initial_sparse_size),
        sparse         = sparse,
        max_id         = 0,
        versioning     = versioning,
        version_bits   = version_bits,
        entity_mask    = entity_mask,
        version_shift  = version_shift,
        version_mask   = version_mask,
    }
}

get_id :: proc(index: EntityIndex, id: u64) -> u64 {
    return id & index.entity_mask
}

get_version :: proc(index: EntityIndex, id: u64) -> u64 {
    return (id >> index.version_shift) & ((1 << index.version_bits) - 1)
}

increment_version :: proc(index: EntityIndex, id: u64) -> u64 {
    current_version := get_version(index, id)
    new_version := (current_version + 1) & ((1 << index.version_bits) - 1)
    return (id & index.entity_mask) | (new_version << index.version_shift)
}

resize_sparse :: proc(index: ^EntityIndex, new_size: u64) {
    old_size := len(index.sparse)
    new_size := max(new_size, u64(old_size) * 2)
    if new_size <= u64(old_size) {
        return
    }
    additional := int(new_size) - old_size
    new_sparse := make([]u64, int(new_size))
    copy(new_sparse, index.sparse)
    for i := old_size; i < int(new_size); i += 1 {
        new_sparse[i] = 0xFFFFFFFFFFFFFFFF
    }
    delete(index.sparse)
    index.sparse = new_sparse
}

add_entity_id :: proc(index: ^EntityIndex) -> u64 {
    if index.alive_count > 0 && index.alive_count < u64(len(index.dense)) {
        recycled_id := index.dense[index.alive_count]
        if recycled_id >= u64(len(index.sparse)) {
            resize_sparse(index, recycled_id + 1)
        }
        index.sparse[recycled_id] = index.alive_count
        index.alive_count += 1
        return recycled_id
    }

    index.max_id += 1
    id := index.max_id
    append(&index.dense, id)

    if id >= u64(len(index.sparse)) {
        new_size := max(id + 1, u64(len(index.sparse))*2)
        resize_sparse(index, new_size)
    }

    index.sparse[id] = index.alive_count
    index.alive_count += 1

    return id
}

remove_entity_id :: proc(index: ^EntityIndex, id: u64) {
    if id >= u64(len(index.sparse)) {
        return
    }
    dense_index := index.sparse[id]
    if dense_index == 0xFFFFFFFFFFFFFFFF || dense_index >= index.alive_count {
        return
    }

    last_index := index.alive_count - 1
    last_id := index.dense[last_index]

    index.sparse[last_id] = dense_index
    index.dense[dense_index] = last_id

    if index.versioning {
        new_id := increment_version(index^, id)
        index.dense[last_index] = new_id
    } else {
        index.dense[last_index] = id
    }

    index.alive_count -= 1
    index.sparse[id] = 0xFFFFFFFFFFFFFFFF
}

is_entity_id_alive :: proc(index: ^EntityIndex, id: u64) -> bool {
    if id >= u64(len(index.sparse)) {
        return false
    }
    entity_id := get_id(index^, id)
    if entity_id >= u64(len(index.sparse)) {
        return false
    }
    dense_index := index.sparse[entity_id]
    return dense_index != 0xFFFFFFFFFFFFFFFF && dense_index < index.alive_count && index.dense[dense_index] == id
}

main :: proc() {
    {
        index := create_entity_index(false, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id1 := add_entity_id(&index)
        id2 := add_entity_id(&index)
        id3 := add_entity_id(&index)
        fmt.printf("id1: %v, id2: %v, id3: %v\n", id1, id2, id3)
        
        if id1 != 1 || id2 != 2 || id3 != 3 {
            panic("Entity IDs not assigned correctly")
        }

        remove_entity_id(&index, id2)
        assert(!is_entity_id_alive(&index, id2))

        id4 := add_entity_id(&index)
        assert(id4 == id2)
        assert(is_entity_id_alive(&index, id4))
    }

    // Test: Recycle entity IDs correctly
    {
        index := create_entity_index(false, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id1 := add_entity_id(&index)
        id2 := add_entity_id(&index)
        remove_entity_id(&index, id1)
        remove_entity_id(&index, id2)

        id3 := add_entity_id(&index)
        id4 := add_entity_id(&index)

        assert(id3 == id2)
        assert(id4 == id1)

        remove_entity_id(&index, id3)
        remove_entity_id(&index, id4)
    }

    // Test: Handle versioning of recycled IDs
    {
        index := create_entity_index(true, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id1 := add_entity_id(&index)
        remove_entity_id(&index, id1)

        id2 := add_entity_id(&index)
        assert(id2 != id1)
        assert(get_version(index, id2) == 1)
    }

    // Test: Correctly identify alive and dead entity IDs
    {
        index := create_entity_index(false, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id1 := add_entity_id(&index)
        id2 := add_entity_id(&index)
        remove_entity_id(&index, id1)

        assert(!is_entity_id_alive(&index, id1))
        assert(is_entity_id_alive(&index, id2))
    }

    // Test: Add and identify entity IDs with versioning
    {
        index := create_entity_index(true, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id5 := add_entity_id(&index)
        id6 := add_entity_id(&index)
        id7 := add_entity_id(&index)

        assert(is_entity_id_alive(&index, id5))
        assert(is_entity_id_alive(&index, id6))
        assert(is_entity_id_alive(&index, id7))
    }

    // Test: Remove and recycle entity IDs with versioning
    {
        index := create_entity_index(true, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id6 := add_entity_id(&index)
        remove_entity_id(&index, id6)

        assert(!is_entity_id_alive(&index, id6))

        id8 := add_entity_id(&index)
        assert(id8 != id6)
        assert(get_id(index, id8) == 1)
        assert(is_entity_id_alive(&index, id8))
    }

    // Test: Correctly handle entity ID and version
    {
        index := create_entity_index(true, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        id1 := add_entity_id(&index)
        remove_entity_id(&index, id1)
        id2 := add_entity_id(&index)
        remove_entity_id(&index, id2)
        id3 := add_entity_id(&index)

        entity_id1 := get_id(index, id1)
        entity_id2 := get_id(index, id2)
        entity_id3 := get_id(index, id3)

        version1 := get_version(index, id1)
        version2 := get_version(index, id2)
        version3 := get_version(index, id3)

        assert(entity_id1 == 1)
        assert(entity_id2 == 1)
        assert(entity_id3 == 1)

        assert(version1 == 0)
        assert(version2 == 1)
        assert(version3 == 2)
    }

    // Test: Handle versioning with 4 bits
    {
        index := create_entity_index(true, 4)
        defer delete(index.dense)
        defer delete(index.sparse)

        max_version := 15 // 2^4 - 1
        
        id := add_entity_id(&index)
        remove_entity_id(&index, id)

        for i in 0..<max_version {
            id = add_entity_id(&index)
            remove_entity_id(&index, id)
            assert(get_version(index, id) == u64(i + 1))
        }
    
        assert(get_version(index, id) == u64(max_version))
    
        // Next removal and addition should wrap around to version 0
        remove_entity_id(&index, id)
        id = add_entity_id(&index)
        assert(get_version(index, id) == 0)
    
        // One more cycle to ensure it continues working
        remove_entity_id(&index, id)
        id = add_entity_id(&index)
        assert(get_version(index, id) == 1)
    }

    // Test: Handle versioning with 16 bits
    {
        index := create_entity_index(true, 16)
        defer delete(index.dense)
        defer delete(index.sparse)

        max_version := 65535 // 2^16 - 1

        id := add_entity_id(&index)
        for _ in 0..<max_version {
            remove_entity_id(&index, id)
            id = add_entity_id(&index)
        }

        assert(get_version(index, id) == u64(max_version))

        // Next removal and addition should wrap around to version 0
        remove_entity_id(&index, id)
        id = add_entity_id(&index)
        assert(get_version(index, id) == 0)
    }
}
