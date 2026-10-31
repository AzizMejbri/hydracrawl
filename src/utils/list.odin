package utils

import "core:mem"
import vmem "core:mem/virtual"


Node :: struct($T: typeid) {
	content:    T,
	prev, next: ^Node(T),
}

List :: struct($T: typeid) {
	head, tail: ^Node(T),
	allocator:  mem.Allocator,
	arena:      vmem.Arena,
}

list_is_empty :: proc(l: ^List($T)) -> bool {
	return l.head == nil
}

@(private = "file")
list_is_singleton :: proc(l: ^List($T)) -> bool {
	return l.head != nil && l.head == l.tail
}

list_init :: proc(l: ^List($T)) -> (err: mem.Allocator_Error) {
	l.head = nil
	l.tail = nil
	if err = vmem.arena_init_growing(&l.arena); err != nil {
		return err
	}
	l.allocator = vmem.arena_allocator(&l.arena)
	return nil
}

list_deinit :: proc(l: ^List($T)) {
	vmem.arena_destroy(&l.arena)
	l^ = {}
}

list_push :: proc(l: ^List($T), element: T) {
	node := new(Node(T), l.allocator)
	node^ = Node(T) {
		content = element,
		prev    = l.tail,
		next    = nil,
	}
	if l.tail != nil {
		l.tail.next = node
	} else {
		l.head = node
	}
	l.tail = node
}

list_pop :: proc(l: ^List($T)) -> (out: T, ok: bool) {
	if l.tail == nil {
		return {}, false
	}
	result := l.tail.content
	if l.head == l.tail {
		l.head = nil
		l.tail = nil
	} else {
		l.tail = l.tail.prev
		l.tail.next = nil
	}
	return result, true
}

list_pop_head :: proc(l: ^List($T)) -> (out: T, ok: bool) {
	if l.head == nil {
		return {}, false
	}
	result := l.head.content
	if l.head == l.tail {
		l.head = nil
		l.tail = nil
	} else {
		l.head = l.head.next
		l.head.prev = nil
	}
	return result, true
}

list_push_head :: proc(l: ^List($T), element: T) {
	node := new(Node(T), l.allocator)
	node^ = Node(T) {
		content = element,
		prev    = nil,
		next    = l.head,
	}
	if l.head != nil {
		l.head.prev = node
	} else {
		l.tail = node
	}
	l.head = node
}

list_peek_head :: proc(l: ^List($T)) -> (out: T, ok: bool) {
	if l.head == nil {
		return {}, false
	}
	return l.head.content, true
}

list_peek_tail :: proc(l: ^List($T)) -> (out: T, ok: bool) {
	if l.tail == nil {
		return {}, false
	}
	return l.tail.content, true
}
