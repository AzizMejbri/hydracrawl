package server

import "core:sys/linux"
import "core:testing"
import green "../green"
import store "../store"

// listener (server.odin) runs forever by design -- a real server never
// stops accepting. That means the scheduler holding it can never reach
// alive == 0 on its own, so this test can't call green.run() to
// completion like every other test in this project does. Instead,
// drive_until manually ticks the scheduler a bounded number of times and
// stops as soon as the client fiber being tested has signaled
// completion -- the listener fiber (and its now-permanently-blocked
// "waiting for the next connection" state) is simply abandoned when the
// test function returns. That's an accepted, bounded, one-time leak
// (one Fiber + its stack), not a product defect: it's the natural cost
// of integration-testing an intentionally-infinite loop in-process
// rather than out-of-process.
//
// This also has to go through green.request/green.spawn (the global
// g_scheduler convenience wrappers in green.odin), not a locally
// constructed Scheduler -- listener and conn_loop are written against
// those global wrappers directly (the same way main.odin uses them),
// so a separate local Scheduler would just sit there unused while
// listener's own green.request calls reach for g_scheduler regardless.
// Confirmed by a real SIGSEGV/ensure-failure the first time this was
// written against a local Scheduler instead.
@(private = "file")
drive_until :: proc(done: ^bool, max_ticks := 20_000) {
  for i := 0; i < max_ticks && !done^; i += 1 {
    green.schedule(&green.g_scheduler)
  }
}

// scripted_client closes its socket before done^ flips true (defers run in
// reverse declaration order), so the peer really has gone away by the time
// drive_until stops -- but the server's conn_loop fiber won't notice that
// EOF until the scheduler gets another tick to drain it. Without this, that
// still-blocked conn_loop (and its stack, send buffer, arena-backed RESP
// values, and per-connection logger) gets abandoned and leaks. Ticking until
// only the listener fiber remains alive can't hang: the EOF completion is
// already queued up, not waiting on a client that will never arrive.
@(private = "file")
drain_connections :: proc(max_ticks := 20_000) {
  for i := 0; i < max_ticks && green.g_scheduler.alive > 1; i += 1 {
    green.schedule(&green.g_scheduler)
  }
}

@(private = "file")
Script_Step :: struct {
  send:   []u8,
  expect: []u8,
}

@(private = "file")
Client_Args :: struct {
  port:   int,
  steps:  []Script_Step,
  passed: ^bool,
  done:   ^bool,
}

// Connects to 127.0.0.1:port and, for each step, sends step.send and
// asserts the reply is byte-for-byte step.expect -- all through the real
// green.request/ring path, the same one conn_loop uses, not a mock.
@(private = "file")
scripted_client :: proc(args: Client_Args) {
  defer {
    args.done^ = true
  }

  client_fd, cferr := linux.socket(.INET, .STREAM, {}, .TCP)
  if cferr != .NONE {
    return
  }
  defer linux.close(client_fd)

  connect_addr := linux.Sock_Addr_Any{
    ipv4 = {sin_family = .INET, sin_port = u16be(u16(args.port)), sin_addr = {127, 0, 0, 1}},
  }
  connect_params: green.Request_Params = green.Connect_Params{fd = client_fd, addr = &connect_addr}
  if green.request(&connect_params) != 0 {
    return
  }

  for step in args.steps {
    send_params: green.Request_Params = green.Send_Params{fd = client_fd, buf = step.send}
    if green.request(&send_params) != i32(len(step.send)) {
      return
    }

    recv_buf := make([]u8, 256)
    defer delete(recv_buf)
    recv_params: green.Request_Params = green.Recv_Params{fd = client_fd, buf = recv_buf}
    n := green.request(&recv_params)
    if n < 0 || string(recv_buf[:n]) != string(step.expect) {
      return
    }
  }

  args.passed^ = true
}

@(private = "file")
run_script :: proc(port: int, steps: []Script_Step) -> bool {
  passed := false
  done := false
  green.spawn(scripted_client, Client_Args{port = port, steps = steps, passed = &passed, done = &done})
  drive_until(&done)
  drain_connections()
  return passed
}

// One real server (listener spawned on the global scheduler, same as
// main.odin does), exercised by several scripted clients in sequence:
// multiple commands on one connection (proving conn_loop's recv ->
// parse -> dispatch -> write -> send loop actually repeats, not just
// runs once), a malformed message (proving it replies with an Error
// instead of hanging or crashing), and SET on one connection followed by
// GET on a brand-new, later connection (proving store persistence
// survives a connection closing -- store.odin's own allocator, as
// opposed to a connection's short-lived arena, exists specifically to
// guarantee this).
@(test)
test_integration_server_end_to_end :: proc(t: ^testing.T) {
  TEST_PORT :: 16501

  data: store.Store
  store.store_init(&data)
  defer store.store_deinit(&data)
  context.user_ptr = &data // same convention main.odin uses -- conn_loop reads this, not a parameter

  green.rt_init()
  defer green.rt_deinit()

  green.spawn(listener, TEST_PORT)
  // give the listener its first turn (bind+listen+first accept-submit)
  // before any client tries to connect.
  green.schedule(&green.g_scheduler)

  multi_cmd_passed := run_script(TEST_PORT, []Script_Step{
    {send = transmute([]u8)string("*1\r\n$4\r\nPING\r\n"), expect = transmute([]u8)string("+PONG\r\n")},
    {send = transmute([]u8)string("*3\r\n$3\r\nSET\r\n$1\r\nk\r\n$1\r\nv\r\n"), expect = transmute([]u8)string("+OK\r\n")},
    {send = transmute([]u8)string("*2\r\n$3\r\nGET\r\n$1\r\nk\r\n"), expect = transmute([]u8)string("$1\r\nv\r\n")},
  })
  testing.expect(t, multi_cmd_passed, "single-connection multi-command script should complete with matching replies")

  malformed_passed := run_script(TEST_PORT, []Script_Step{
    // not valid RESP framing at all (no *.../$.../+.../-.../:... prefix),
    // so this fails at parse time, not dispatch -- same "unexpected
    // token" error already verified manually earlier against "hi\r\n"
    {send = transmute([]u8)string("garbage\r\n"), expect = transmute([]u8)string("-unexpected token\r\n")},
  })
  testing.expect(t, malformed_passed, "a malformed message should get a RESP Error reply, not a hang or crash")

  set_passed := run_script(TEST_PORT, []Script_Step{
    {send = transmute([]u8)string("*3\r\n$3\r\nSET\r\n$3\r\nfoo\r\n$3\r\nbar\r\n"), expect = transmute([]u8)string("+OK\r\n")},
  })
  testing.expect(t, set_passed, "SET on connection A should succeed")

  get_passed := run_script(TEST_PORT, []Script_Step{
    {send = transmute([]u8)string("*2\r\n$3\r\nGET\r\n$3\r\nfoo\r\n"), expect = transmute([]u8)string("$3\r\nbar\r\n")},
  })
  testing.expect(t, get_passed, "GET on a separate, later connection B should see the value SET by connection A")

  // Deliberately not draining further here: run_script already drained
  // connections down to just the listener after each script. The only
  // thing still outstanding now is the listener's own accept, which will
  // never complete (no more clients) -- an extra schedule() tick would
  // block forever on ring_drain(wait_nr=1) waiting for a connection that
  // will never come. The one remaining leak the memory tracker reports
  // below (the listener's Fiber+stack) is exactly that bounded, by-design
  // cost, not a product defect -- confirmed, not just asserted.
}
