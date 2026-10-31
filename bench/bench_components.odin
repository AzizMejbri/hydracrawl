package main

import "core:time"
import resp "../src/resp"
import store "../src/store"
import server "../src/server"

ITERS_RESP     :: 100_000
ITERS_STORE    :: 100_000
ITERS_DISPATCH :: 100_000
ITERS_PIPELINE :: 50_000

// ---------------------------------------------------------------------------
// resp: parser and writer in isolation -- no store, no dispatch, no
// scheduler. Isolates the pure wire-bytes <-> Value cost.

@(private = "file")
set_wire := []u8{
  '*', '3', '\r', '\n',
  '$', '3', '\r', '\n', 'S', 'E', 'T', '\r', '\n',
  '$', '3', '\r', '\n', 'f', 'o', 'o', '\r', '\n',
  '$', '3', '\r', '\n', 'b', 'a', 'r', '\r', '\n',
}

bench_resp_parse :: proc() {
  start := time.tick_now()
  for _ in 0 ..< ITERS_RESP {
    v, ok, errors := resp.parse(set_wire)
    assert(ok)
    resp.deinit_value(&v)
    delete(errors)
  }
  d := time.tick_diff(start, time.tick_now())
  report("resp.parse (SET foo bar wire)", ITERS_RESP, d)
}

bench_resp_write :: proc() {
  value: resp.Value = resp.Bulk_String{len = 3, items = []u8{'b', 'a', 'r'}}
  buf: [dynamic]u8
  defer delete(buf)
  reserve(&buf, 32)

  start := time.tick_now()
  for _ in 0 ..< ITERS_RESP {
    clear(&buf)
    resp.resp_write(&buf, value)
  }
  d := time.tick_diff(start, time.tick_now())
  report("resp.resp_write (bulk reply)", ITERS_RESP, d)
}

// ---------------------------------------------------------------------------
// store: direct SET/GET/INCR against the map -- no RESP, no dispatch.

bench_store_set :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  value: resp.Value = resp.Bulk_String{len = 3, items = []u8{'b', 'a', 'r'}}

  start := time.tick_now()
  for _ in 0 ..< ITERS_STORE {
    reply := store.set(&s, "foo", value)
    resp.deinit_value(&reply)
  }
  d := time.tick_diff(start, time.tick_now())
  report("store.set (overwrite same key)", ITERS_STORE, d)
}

bench_store_get :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  value: resp.Value = resp.Bulk_String{len = 3, items = []u8{'b', 'a', 'r'}}
  seed := store.set(&s, "foo", value)
  resp.deinit_value(&seed)

  start := time.tick_now()
  for _ in 0 ..< ITERS_STORE {
    reply := store.get(&s, "foo")
    resp.deinit_value(&reply)
  }
  d := time.tick_diff(start, time.tick_now())
  report("store.get (existing key)", ITERS_STORE, d)
}

bench_store_incr :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  start := time.tick_now()
  for _ in 0 ..< ITERS_STORE {
    reply := store.incr(&s, "counter")
    resp.deinit_value(&reply)
  }
  d := time.tick_diff(start, time.tick_now())
  report("store.incr (same counter)", ITERS_STORE, d)
}

// ---------------------------------------------------------------------------
// server.dispatch_value: command-table lookup + handler, pre-built
// Value command (isolates dispatch/handler cost from parsing cost).

@(private = "file")
command_value :: proc(parts: ..string) -> resp.Value {
  items := make([]resp.Value, len(parts))
  for part, i in parts {
    b := make([]u8, len(part))
    copy(b, transmute([]u8)part)
    items[i] = resp.Bulk_String{len = uint(len(part)), items = b}
  }
  return resp.Array{len = uint(len(parts)), items = items}
}

bench_dispatch_set :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  cmd := command_value("SET", "foo", "bar")
  defer resp.deinit_value(&cmd)

  start := time.tick_now()
  for _ in 0 ..< ITERS_DISPATCH {
    reply := server.dispatch_value(&s, cmd)
    resp.deinit_value(&reply)
  }
  d := time.tick_diff(start, time.tick_now())
  report("dispatch_value (SET)", ITERS_DISPATCH, d)
}

bench_dispatch_get :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  seed_cmd := command_value("SET", "foo", "bar")
  seed_reply := server.dispatch_value(&s, seed_cmd)
  resp.deinit_value(&seed_reply)
  resp.deinit_value(&seed_cmd)

  cmd := command_value("GET", "foo")
  defer resp.deinit_value(&cmd)

  start := time.tick_now()
  for _ in 0 ..< ITERS_DISPATCH {
    reply := server.dispatch_value(&s, cmd)
    resp.deinit_value(&reply)
  }
  d := time.tick_diff(start, time.tick_now())
  report("dispatch_value (GET)", ITERS_DISPATCH, d)
}

// ---------------------------------------------------------------------------
// Full wire-to-wire pipeline, no socket I/O: parse -> dispatch -> write.
// This is exactly conn_loop's per-message CPU cost minus the actual
// send/recv syscalls -- the number to compare against the io_uring
// round-trip costs already measured in bench.odin.

bench_pipeline_set :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  send_buf: [dynamic]u8
  defer delete(send_buf)
  reserve(&send_buf, 64)

  start := time.tick_now()
  for _ in 0 ..< ITERS_PIPELINE {
    v, ok, errors := resp.parse(set_wire)
    assert(ok)
    reply := server.dispatch_value(&s, v)
    clear(&send_buf)
    resp.resp_write(&send_buf, reply)
    resp.deinit_value(&reply)
    resp.deinit_value(&v)
    delete(errors)
  }
  d := time.tick_diff(start, time.tick_now())
  report("pipeline (wire SET -> wire reply)", ITERS_PIPELINE, d)
}

bench_pipeline_get :: proc() {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  seed_v, seed_ok, seed_errors := resp.parse(set_wire)
  assert(seed_ok)
  seed_reply := server.dispatch_value(&s, seed_v)
  resp.deinit_value(&seed_reply)
  resp.deinit_value(&seed_v)
  delete(seed_errors)

  get_wire := []u8{
    '*', '2', '\r', '\n',
    '$', '3', '\r', '\n', 'G', 'E', 'T', '\r', '\n',
    '$', '3', '\r', '\n', 'f', 'o', 'o', '\r', '\n',
  }

  send_buf: [dynamic]u8
  defer delete(send_buf)
  reserve(&send_buf, 64)

  start := time.tick_now()
  for _ in 0 ..< ITERS_PIPELINE {
    v, ok, errors := resp.parse(get_wire)
    assert(ok)
    reply := server.dispatch_value(&s, v)
    clear(&send_buf)
    resp.resp_write(&send_buf, reply)
    resp.deinit_value(&reply)
    resp.deinit_value(&v)
    delete(errors)
  }
  d := time.tick_diff(start, time.tick_now())
  report("pipeline (wire GET -> wire reply)", ITERS_PIPELINE, d)
}
