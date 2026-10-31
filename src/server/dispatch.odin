package server

import "core:fmt"
import "core:strings"
import cmd "./command"
import resp "../resp"
import store "../store"

Handler :: #type proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value

@(private)
errorf :: proc(format: string, args: ..any) -> resp.Value {
  msg := fmt.aprintf(format, ..args)
  defer delete(msg)
  return resp.error_from_string(msg)
}

@(private)
handler_table := [?]struct {
  name: string,
  run: Handler,
}{
  {"PING", cmd.handle_ping},
  {"ECHO", cmd.handle_echo},
  {"GET", cmd.handle_get},
  {"SET", cmd.handle_set},
  {"APPEND", cmd.handle_append},
  {"STRLEN", cmd.handle_strlen},
  {"INCR", cmd.handle_incr},
  {"DECR", cmd.handle_decr},
  {"INCRBY", cmd.handle_incrby},
  {"DECRBY", cmd.handle_decrby},
  {"INCRBYFLOAT", cmd.handle_incrbyfloat},
  {"GETSET", cmd.handle_getset},
  {"GETDEL", cmd.handle_getdel},
  {"GETRANGE", cmd.handle_getrange},
  {"SETRANGE", cmd.handle_setrange},
  {"MGET", cmd.handle_mget},
  {"MSET", cmd.handle_mset},
  {"SETEX", cmd.handle_setex},
  {"SETNX", cmd.handle_setnx},
  {"LPUSH", cmd.handle_lpush},
  {"RPUSH", cmd.handle_rpush},
  {"LPOP", cmd.handle_lpop},
  {"RPOP", cmd.handle_rpop},
  {"LRANGE", cmd.handle_lrange},
  {"LLEN", cmd.handle_llen},
  {"LINDEX", cmd.handle_lindex},
  {"LINSERT", cmd.handle_linsert},
  {"LREM", cmd.handle_lrem},
  {"LSET", cmd.handle_lset},
  {"LTRIM", cmd.handle_ltrim},
  {"BLPOP", cmd.handle_blpop},
  {"BRPOP", cmd.handle_brpop},
  {"LMOVE", cmd.handle_lmove},
  {"DEL", cmd.handle_del},
  {"EXISTS", cmd.handle_exists},
  {"EXPIRE", cmd.handle_expire},
  {"TTL", cmd.handle_ttl},
  {"PERSIST", cmd.handle_persist},
  {"TYPE", cmd.handle_type},
  {"KEYS", cmd.handle_keys},
  {"SCAN", cmd.handle_scan},
  {"RENAME", cmd.handle_rename},
  {"RANDOMKEY", cmd.handle_randomkey},
}

dispatch_args :: proc(s: ^store.Store, name: []u8, args: []resp.Bulk_String) -> resp.Value {
  for entry in handler_table {
    if strings.equal_fold(string(name), entry.name) {
      return entry.run(s, args)
    }
  }
  return errorf("ERR unknown command '%s'", string(name))
}

dispatch_value :: proc(s: ^store.Store, v: resp.Value) -> resp.Value {
  array, ok := v.(resp.Array)
  if !ok || array.is_null {
    return resp.error_from_string("ERR Protocol error: expected array")
  }
  if len(array.items) == 0 {
    return resp.error_from_string("ERR Protocol error: empty command")
  }

  name, name_ok := array.items[0].(resp.Bulk_String)
  if !name_ok || name.is_null {
    return resp.error_from_string("ERR Protocol error: expected bulk string")
  }

  args := make([]resp.Bulk_String, len(array.items) - 1)
  defer delete(args)

  for item, i in array.items[1:] {
    arg, arg_ok := item.(resp.Bulk_String)
    if !arg_ok || arg.is_null {
      return resp.error_from_string("ERR Protocol error: expected bulk string")
    }
    args[i] = arg
  }

  return dispatch_args(s, name.items, args)
}
