package command

import "core:testing"
import resp "../../resp"
import store "../../store"

@(private = "file")
bulk :: proc(s: string) -> resp.Bulk_String {
  items := make([]u8, len(s))
  copy(items, transmute([]u8)s)
  return resp.Bulk_String{len = uint(len(s)), items = items}
}

@(private = "file")
args :: proc(parts: ..string) -> []resp.Bulk_String {
  out := make([]resp.Bulk_String, len(parts))
  for part, i in parts {
    out[i] = bulk(part)
  }
  return out
}

@(private = "file")
free_args :: proc(a: []resp.Bulk_String) {
  for arg in a {
    delete(arg.items)
  }
  delete(a)
}

@(test)
test_handle_ping :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  a := args()
  defer free_args(a)
  reply := handle_ping(&s, a)
  defer resp.deinit_value(&reply)
  ss, ok := reply.(resp.Simple_String)
  testing.expect(t, ok && string(ss.items) == "PONG")
}

@(test)
test_handle_echo_wrong_arity :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  a := args()
  defer free_args(a)
  reply := handle_echo(&s, a)
  defer resp.deinit_value(&reply)
  err, ok := reply.(resp.Error)
  testing.expect(t, ok && string(resp.error_kind(err)) == "ARITY_ERROR")
}

@(test)
test_handle_set_then_get :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  set_args := args("k", "v")
  defer free_args(set_args)
  set_reply := handle_set(&s, set_args)
  defer resp.deinit_value(&set_reply)
  ss, ok := set_reply.(resp.Simple_String)
  testing.expect(t, ok && string(ss.items) == "OK")

  get_args := args("k")
  defer free_args(get_args)
  get_reply := handle_get(&s, get_args)
  defer resp.deinit_value(&get_reply)
  b, bok := get_reply.(resp.Bulk_String)
  testing.expect(t, bok && !b.is_null && string(b.items) == "v")
}

@(test)
test_handle_incr_on_missing_key :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  a := args("counter")
  defer free_args(a)
  reply := handle_incr(&s, a)
  defer resp.deinit_value(&reply)
  n, ok := reply.(resp.Integer)
  testing.expect(t, ok && n.raw == 1)
}

@(test)
test_handle_rpush_then_lrange :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  push_args := args("mylist", "a", "b")
  defer free_args(push_args)
  push_reply := handle_rpush(&s, push_args)
  defer resp.deinit_value(&push_reply)
  n, ok := push_reply.(resp.Integer)
  testing.expect(t, ok && n.raw == 2)

  range_args := args("mylist", "0", "-1")
  defer free_args(range_args)
  range_reply := handle_lrange(&s, range_args)
  defer resp.deinit_value(&range_reply)
  arr, aok := range_reply.(resp.Array)
  testing.expect(t, aok && len(arr.items) == 2)
  if aok && len(arr.items) == 2 {
    first, fok := arr.items[0].(resp.Bulk_String)
    testing.expect(t, fok && string(first.items) == "a")
  }
}

@(test)
test_handle_lpush_wrongtype_on_string_key :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  set_args := args("k", "v")
  defer free_args(set_args)
  set_reply := handle_set(&s, set_args)
  resp.deinit_value(&set_reply)

  push_args := args("k", "x")
  defer free_args(push_args)
  reply := handle_lpush(&s, push_args)
  defer resp.deinit_value(&reply)
  err, ok := reply.(resp.Error)
  testing.expect(t, ok && string(resp.error_kind(err)) == "WRONGTYPE")
}

@(test)
test_handle_exists_and_del :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  set_args := args("a", "1")
  defer free_args(set_args)
  set_reply := handle_set(&s, set_args)
  resp.deinit_value(&set_reply)

  exists_args := args("a", "missing")
  defer free_args(exists_args)
  exists_reply := handle_exists(&s, exists_args)
  defer resp.deinit_value(&exists_reply)
  en, eok := exists_reply.(resp.Integer)
  testing.expect(t, eok && en.raw == 1)

  del_args := args("a", "missing")
  defer free_args(del_args)
  del_reply := handle_del(&s, del_args)
  defer resp.deinit_value(&del_reply)
  dn, dok := del_reply.(resp.Integer)
  testing.expect(t, dok && dn.raw == 1)
}

@(test)
test_handle_type :: proc(t: ^testing.T) {
  s: store.Store
  store.store_init(&s)
  defer store.store_deinit(&s)

  set_args := args("s", "v")
  defer free_args(set_args)
  set_reply := handle_set(&s, set_args)
  resp.deinit_value(&set_reply)

  push_args := args("l", "v")
  defer free_args(push_args)
  push_reply := handle_rpush(&s, push_args)
  resp.deinit_value(&push_reply)

  string_type_args := args("s")
  defer free_args(string_type_args)
  string_type := handle_type(&s, string_type_args)
  defer resp.deinit_value(&string_type)
  st, sok := string_type.(resp.Bulk_String)
  testing.expect(t, sok && string(st.items) == "string")

  list_type_args := args("l")
  defer free_args(list_type_args)
  list_type := handle_type(&s, list_type_args)
  defer resp.deinit_value(&list_type)
  lt, lok := list_type.(resp.Bulk_String)
  testing.expect(t, lok && string(lt.items) == "list")
}
