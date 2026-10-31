package server

import "core:testing"
import resp "../resp"
import store "../store"

@(private)
bulk :: #force_inline proc(s: string) -> resp.Value {
  items := make([]u8, len(s))
  copy(items, transmute([]u8)s)
  return resp.Bulk_String{ len = uint(len(s)), items = items }
}

@(private)
command :: #force_inline proc(parts: ..string) -> resp.Value {
  items := make([]resp.Value, len(parts))
  for part, i in parts {
    items[i] = bulk(part)
  }
  return resp.Array{ len = uint(len(parts)), items = items }
}

@(test)
test_dispatch_set_get :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  set_cmd := command("SET", "greeting", "hello")
  defer resp.deinit_value(&set_cmd)
  set_reply := dispatch_value(&s, set_cmd)
  defer resp.deinit_value(&set_reply)
  ok_set, ok := set_reply.(resp.Simple_String)
  testing.expect(t, ok && string(ok_set.items) == "OK")

  get_cmd := command("get", "greeting")
  defer resp.deinit_value(&get_cmd)
  get_reply := dispatch_value(&s, get_cmd)
  defer resp.deinit_value(&get_reply)
  b, bok := get_reply.(resp.Bulk_String)
  testing.expect(t, bok && !b.is_null && string(b.items) == "hello")

  missing_cmd := command("GET", "missing")
  defer resp.deinit_value(&missing_cmd)
  missing_reply := dispatch_value(&s, missing_cmd)
  defer resp.deinit_value(&missing_reply)
  mb, mbok := missing_reply.(resp.Bulk_String)
  testing.expect(t, mbok && mb.is_null)
}

@(test)
test_dispatch_ping_echo :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  ping_cmd := command("PING")
  defer resp.deinit_value(&ping_cmd)
  ping_reply := dispatch_value(&s, ping_cmd)
  defer resp.deinit_value(&ping_reply)
  pong, ok := ping_reply.(resp.Simple_String)
  testing.expect(t, ok && string(pong.items) == "PONG")

  ping_msg_cmd := command("ping", "hello")
  defer resp.deinit_value(&ping_msg_cmd)
  ping_msg_reply := dispatch_value(&s, ping_msg_cmd)
  defer resp.deinit_value(&ping_msg_reply)
  pong_msg, msg_ok := ping_msg_reply.(resp.Bulk_String)
  testing.expect(t, msg_ok && !pong_msg.is_null && string(pong_msg.items) == "hello")

  echo_cmd := command("ECHO", "world")
  defer resp.deinit_value(&echo_cmd)
  echo_reply := dispatch_value(&s, echo_cmd)
  defer resp.deinit_value(&echo_reply)
  echoed, echo_ok := echo_reply.(resp.Bulk_String)
  testing.expect(t, echo_ok && !echoed.is_null && string(echoed.items) == "world")

  ping_arity := command("PING", "a", "b")
  defer resp.deinit_value(&ping_arity)
  ping_arity_reply := dispatch_value(&s, ping_arity)
  defer resp.deinit_value(&ping_arity_reply)
  pa, paok := ping_arity_reply.(resp.Error)
  testing.expect(t, paok && string(resp.error_kind(pa)) == "ARITY_ERROR")

  echo_arity := command("ECHO")
  defer resp.deinit_value(&echo_arity)
  echo_arity_reply := dispatch_value(&s, echo_arity)
  defer resp.deinit_value(&echo_arity_reply)
  ea, eaok := echo_arity_reply.(resp.Error)
  testing.expect(t, eaok && string(resp.error_kind(ea)) == "ARITY_ERROR")
}

@(test)
test_dispatch_incr_ttl_expire :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  first_cmd := command("INCR", "counter")
  defer resp.deinit_value(&first_cmd)
  first := dispatch_value(&s, first_cmd)
  defer resp.deinit_value(&first)
  f, fok := first.(resp.Integer)
  testing.expect(t, fok && f.raw == 1)

  second_cmd := command("incr", "counter")
  defer resp.deinit_value(&second_cmd)
  second := dispatch_value(&s, second_cmd)
  defer resp.deinit_value(&second)
  sec, sok := second.(resp.Integer)
  testing.expect(t, sok && sec.raw == 2)

  ttl_cmd := command("TTL", "counter")
  defer resp.deinit_value(&ttl_cmd)
  ttl_reply := dispatch_value(&s, ttl_cmd)
  defer resp.deinit_value(&ttl_reply)
  tv, tok := ttl_reply.(resp.Integer)
  testing.expect(t, tok && tv.raw == -1)

  expire_cmd := command("EXPIRE", "counter", "100")
  defer resp.deinit_value(&expire_cmd)
  expire_reply := dispatch_value(&s, expire_cmd)
  defer resp.deinit_value(&expire_reply)
  ev, eok := expire_reply.(resp.Integer)
  testing.expect(t, eok && ev.raw == 1)

  ttl_after_cmd := command("TTL", "counter")
  defer resp.deinit_value(&ttl_after_cmd)
  ttl_after := dispatch_value(&s, ttl_after_cmd)
  defer resp.deinit_value(&ttl_after)
  ta, taok := ttl_after.(resp.Integer)
  testing.expect(t, taok && ta.raw > 0 && ta.raw <= 100)
}

@(test)
test_dispatch_multi_key :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  set_a := command("SET", "a", "1")
  defer resp.deinit_value(&set_a)
  reply_a := dispatch_value(&s, set_a)
  resp.deinit_value(&reply_a)

  set_b := command("SET", "b", "2")
  defer resp.deinit_value(&set_b)
  reply_b := dispatch_value(&s, set_b)
  resp.deinit_value(&reply_b)

  exists_cmd := command("EXISTS", "a", "b", "c")
  defer resp.deinit_value(&exists_cmd)
  exists_reply := dispatch_value(&s, exists_cmd)
  defer resp.deinit_value(&exists_reply)
  ev, eok := exists_reply.(resp.Integer)
  testing.expect(t, eok && ev.raw == 2)

  del_cmd := command("DEL", "a", "b", "c")
  defer resp.deinit_value(&del_cmd)
  del_reply := dispatch_value(&s, del_cmd)
  defer resp.deinit_value(&del_reply)
  dv, dok := del_reply.(resp.Integer)
  testing.expect(t, dok && dv.raw == 2)
}

@(test)
test_dispatch_errors :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  unknown := command("NOPE")
  defer resp.deinit_value(&unknown)
  unknown_reply := dispatch_value(&s, unknown)
  defer resp.deinit_value(&unknown_reply)
  ue, uok := unknown_reply.(resp.Error)
  testing.expect(t, uok && string(resp.error_kind(ue)) == "ERR")
  testing.expect(t, string(resp.error_msg(ue)) == "unknown command 'NOPE'")

  arity := command("GET")
  defer resp.deinit_value(&arity)
  arity_reply := dispatch_value(&s, arity)
  defer resp.deinit_value(&arity_reply)
  ae, aok := arity_reply.(resp.Error)
  testing.expect(t, aok && string(resp.error_kind(ae)) == "ARITY_ERROR")
  testing.expect(t, string(resp.error_msg(ae)) == "wrong number of arguments for 'get' command")

  bad_expire := command("EXPIRE", "key", "soon")
  defer resp.deinit_value(&bad_expire)
  bad_expire_reply := dispatch_value(&s, bad_expire)
  defer resp.deinit_value(&bad_expire_reply)
  be, bok := bad_expire_reply.(resp.Error)
  testing.expect(t, bok && string(resp.error_msg(be)) == "value is not an integer or out of range")

  not_array: resp.Value = resp.Integer{ raw = 1 }
  not_array_reply := dispatch_value(&s, not_array)
  defer resp.deinit_value(&not_array_reply)
  na, naok := not_array_reply.(resp.Error)
  testing.expect(t, naok && string(resp.error_kind(na)) == "ERR")

  empty: resp.Value = resp.Array{}
  defer resp.deinit_value(&empty)
  empty_reply := dispatch_value(&s, empty)
  defer resp.deinit_value(&empty_reply)
  er, erok := empty_reply.(resp.Error)
  testing.expect(t, erok && string(resp.error_kind(er)) == "ERR")

  bad_arg_items := make([]resp.Value, 1)
  bad_arg_items[0] = resp.Simple_String{}
  bad_arg: resp.Value = resp.Array{ len = 1, items = bad_arg_items }
  defer resp.deinit_value(&bad_arg)
  bad_arg_reply := dispatch_value(&s, bad_arg)
  defer resp.deinit_value(&bad_arg_reply)
  ba, baok := bad_arg_reply.(resp.Error)
  testing.expect(t, baok && string(resp.error_kind(ba)) == "ERR")

  null_arg_items := make([]resp.Value, 2)
  null_arg_items[0] = resp.null_bulk()
  null_arg_items[1] = resp.null_bulk()
  null_arg: resp.Value = resp.Array{ len = 2, items = null_arg_items }
  defer resp.deinit_value(&null_arg)
  null_arg_reply := dispatch_value(&s, null_arg)
  defer resp.deinit_value(&null_arg_reply)
  nar, narok := null_arg_reply.(resp.Error)
  testing.expect(t, narok && string(resp.error_kind(nar)) == "ERR")
}

@(test)
test_ping_wire_reply :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  ps: resp.Parser_State
  defer delete(ps.errors)
  p := resp.value_p()
  defer p.destroy(p.ctx)

  wire := []u8{
    '*', '1', '\r', '\n',
    '$', '4', '\r', '\n', 'P', 'I', 'N', 'G', '\r', '\n',
  }
  cmd, ok := p.run(p.ctx, wire, &ps)
  testing.expect(t, ok)
  if !ok {
    return
  }

  reply := dispatch_value(&s, cmd)
  resp.deinit_value(&cmd)

  out: [dynamic]u8
  defer delete(out)
  resp.resp_write(&out, reply)
  resp.deinit_value(&reply)
  testing.expect(t, string(out[:]) == "+PONG\r\n")
}

@(test)
test_pipeline_wire_to_store_to_wire :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  ps: resp.Parser_State
  defer delete(ps.errors)
  p := resp.value_p()
  defer p.destroy(p.ctx)

  set_wire := []u8{
    '*', '3', '\r', '\n',
    '$', '3', '\r', '\n', 'S', 'E', 'T', '\r', '\n',
    '$', '1', '\r', '\n', 'k', '\r', '\n',
    '$', '1', '\r', '\n', 'v', '\r', '\n',
  }
  set_cmd, set_ok := p.run(p.ctx, set_wire, &ps)
  testing.expect(t, set_ok)
  if !set_ok {
    return
  }
  set_reply := dispatch_value(&s, set_cmd)
  resp.deinit_value(&set_cmd)

  set_out: [dynamic]u8
  defer delete(set_out)
  resp.resp_write(&set_out, set_reply)
  resp.deinit_value(&set_reply)
  testing.expect(t, string(set_out[:]) == "+OK\r\n")

  ps.idx = 0
  get_wire := []u8{
    '*', '2', '\r', '\n',
    '$', '3', '\r', '\n', 'G', 'E', 'T', '\r', '\n',
    '$', '1', '\r', '\n', 'k', '\r', '\n',
  }
  get_cmd, get_ok := p.run(p.ctx, get_wire, &ps)
  testing.expect(t, get_ok)
  if !get_ok {
    return
  }
  get_reply := dispatch_value(&s, get_cmd)
  resp.deinit_value(&get_cmd)

  get_out: [dynamic]u8
  defer delete(get_out)
  resp.resp_write(&get_out, get_reply)
  resp.deinit_value(&get_reply)
  testing.expect(t, string(get_out[:]) == "$1\r\nv\r\n")
}
