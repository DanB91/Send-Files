package main
Pool :: struct($T, $ID: typeid, $N: int) {
	pool:      [N]PoolEntry(T, ID),
	next_free: ID,
	free_list: ID,
}

PoolEntry :: struct($T, $ID: typeid) {
	value:   T,
	next:    ID,
	is_used: bool,
}

pool_alloc_and_init :: proc(pool: ^Pool($T, $ID, $N), value: T) -> ID {
	if pool.free_list != 0 {
		result := pool.free_list
		entry := &pool.pool[result]
		pool.next_free = entry.next
		entry.next = 0
		entry.value = value
		return result

	} else {
		for _ in 0 ..< N {
			pool.next_free += 1
			pool.next_free %= auto_cast N
			entry := &pool.pool[pool.next_free]
			if !entry.is_used {
				result := pool.next_free
				entry.is_used = true
				entry.next = 0
				entry.value = value
				return result
			}
		}
		ensure(false)
		return 0
	}

}

pool_free :: proc(pool: ^Pool($T, $ID, $N), id: ID) {
	entry := &pool.pool[id]
	entry.is_used = false
	entry.next = pool.free_list
	pool.free_list = id
}

pool_ptr_from_id :: proc(pool: ^Pool($T, $ID, $N), id: ID) -> ^T {
	result := &pool.pool[id].value
	return result
}
