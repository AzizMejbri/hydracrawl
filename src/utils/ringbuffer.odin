package utils

// Invariant: head == tail ⟺ empty
//            (tail + 1) % (N+1) == head ⟺ full
// Capacity = N, one slot is kept empty to distinguish full from empty.
Ring_Buffer :: struct($T: typeid, $N: uint) {
	buf:  [N + 1]T,
	head: uint, // next slot to read
	tail: uint, // next slot to write
}

rb_init :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) {
	rb.head = 0
	rb.tail = 0
}

rb_clear :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) {
	rb.head = 0
	rb.tail = 0
}

rb_is_empty :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> bool {
	return rb.head == rb.tail
}

rb_is_full :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> bool {
	return (rb.tail + 1) % (N + 1) == rb.head
}

rb_len :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> uint {
	return (rb.tail + (N + 1) - rb.head) % (N + 1)
}

rb_capacity :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> uint {
	return N
}

rb_push :: proc "contextless" (rb: ^Ring_Buffer($T, $N), v: T) -> bool {
	if rb_is_full(rb) {
		return false
	}
	rb.buf[rb.tail] = v
	rb.tail = (rb.tail + 1) % (N + 1)
	return true
}

rb_pop :: proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> (v: T, ok: bool) {
	if rb_is_empty(rb) {
		return {}, false
	}
	v = rb.buf[rb.head]
	rb.head = (rb.head + 1) % (N + 1)
	return v, true
}

rb_peek :: proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> (v: T, ok: bool) {
	if rb_is_empty(rb) {
		return {}, false
	}
	return rb.buf[rb.head], true
}

// Read-only, head-to-tail traversal. Keeps $T/$N on the iterator itself
// (a typed pointer back to rb) rather than erasing them through a rawptr —
// a rawptr has no fields, and N wouldn't be recoverable from it anyway.
Ring_Buffer_Iter :: struct($T: typeid, $N: uint) {
	rb:  ^Ring_Buffer(T, N),
	idx: uint,
}

rb_iter :: #force_inline proc "contextless" (rb: ^Ring_Buffer($T, $N)) -> Ring_Buffer_Iter(T, N) {
	return Ring_Buffer_Iter(T, N){rb = rb, idx = rb.head}
}

// Usage: it := rb_iter(&rb); for v in rb_iter_next(&it) { ... }
rb_iter_next :: proc "contextless" (it: ^Ring_Buffer_Iter($T, $N)) -> (val: T, ok: bool) {
	if it.idx == it.rb.tail {
		return {}, false
	}
	val = it.rb.buf[it.idx]
	it.idx = (it.idx + 1) % (N + 1)
	ok = true
	return
}

rb_iter_next_ptr :: #force_inline proc "contextless" (it: ^Ring_Buffer_Iter($T, $N)) -> (val: ^T, ok: bool) {
	if it.idx == it.rb.tail {
		return nil, false
	}
	val = &it.rb.buf[it.idx]
	it.idx = (it.idx + 1) % (N + 1)
	return val, true
}
