package utils

import "core:mem"
import "core:testing"

@(test)
test_list_push_pop :: proc(t: ^testing.T) {
	l: List(int)
	err := list_init(&l)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer list_deinit(&l)

	testing.expect(t, list_is_empty(&l), "fresh list should be empty")

	list_push(&l, 1)
	list_push(&l, 2)
	list_push(&l, 3)

	testing.expect(t, !list_is_empty(&l), "list should not be empty after pushes")

	v, ok := list_pop(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 3)

	v, ok = list_pop(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 2)

	v, ok = list_pop(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)

	_, ok = list_pop(&l)
	testing.expect(t, !ok, "pop on empty list should fail")
}

@(test)
test_list_push_head_pop_head :: proc(t: ^testing.T) {
	l: List(int)
	err := list_init(&l)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer list_deinit(&l)

	list_push_head(&l, 1)
	list_push_head(&l, 2)
	list_push_head(&l, 3)
	// list is now, head to tail: 3, 2, 1

	v, ok := list_pop_head(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 3)

	v, ok = list_pop_head(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 2)

	v, ok = list_pop_head(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 1)

	_, ok = list_pop_head(&l)
	testing.expect(t, !ok, "pop_head on empty list should fail")
}

@(test)
test_list_peek_does_not_mutate :: proc(t: ^testing.T) {
	l: List(int)
	err := list_init(&l)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer list_deinit(&l)

	_, hempty := list_peek_head(&l)
	testing.expect(t, !hempty, "peek_head on empty list should fail")
	_, tempty := list_peek_tail(&l)
	testing.expect(t, !tempty, "peek_tail on empty list should fail")

	list_push(&l, 10)
	list_push(&l, 20)

	h, hok := list_peek_head(&l)
	testing.expect(t, hok)
	testing.expect_value(t, h, 10)

	tl, tok := list_peek_tail(&l)
	testing.expect(t, tok)
	testing.expect_value(t, tl, 20)

	// peeking twice must return the same thing — no mutation.
	h2, _ := list_peek_head(&l)
	testing.expect_value(t, h2, 10)
	testing.expect(t, !list_is_empty(&l))
}

@(test)
test_list_single_element_either_end :: proc(t: ^testing.T) {
	l: List(int)
	err := list_init(&l)
	testing.expect_value(t, err, mem.Allocator_Error.None)
	defer list_deinit(&l)

	list_push(&l, 42)
	v, ok := list_pop_head(&l)
	testing.expect(t, ok)
	testing.expect_value(t, v, 42)
	testing.expect(t, list_is_empty(&l))
}
