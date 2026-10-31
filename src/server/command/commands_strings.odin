package command

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"
import resp "../../resp"
import store "../../store"

Set_TTL :: enum {
  None,
  EX,
  PX,
  EXAT,
  PXAT,
  KEEPTTL,
}

@(private)
unix_millis :: proc() -> u64 {
  nanos := time.time_to_unix_nano(time.now())
  if nanos <= 0 {
    return 0
  }
  return u64(nanos / 1_000_000)
}

@(private)
expiry_with_saturate :: proc(base, delta: u64) -> u64 {
  if delta > max(u64) - base {
    return max(u64)
  }
  return base + delta
}

@(private)
seconds_to_millis :: proc(seconds: u64) -> u64 {
  if seconds > max(u64) / 1000 {
    return max(u64)
  }
  return seconds * 1000
}

@(private)
ttl_millis :: proc(mode: Set_TTL, value: i64) -> u64 {
  switch mode {
  case .EX:
    return expiry_with_saturate(unix_millis(), seconds_to_millis(u64(value)))
  case .PX:
    return expiry_with_saturate(unix_millis(), u64(value))
  case .EXAT:
    return seconds_to_millis(u64(value))
  case .PXAT:
    return u64(value)
  case .None, .KEEPTTL:
    return 0
  }
  return 0
}

@(private)
float_error :: proc() -> resp.Value {
  return resp.error_from_string("ERR value is not a valid float")
}

@(private)
value_as_bulk :: proc(v: resp.Value) -> resp.Value {
  switch x in v {
  case resp.Bulk_String:
    return resp.init_value(v)
  case resp.Simple_String:
    return resp.Bulk_String{len = uint(len(x.items)), items = clone_bytes(x.items)}
  case resp.Integer:
    return bulk_from_int(x.raw)
  case resp.Error, resp.Array:
    return resp.Value{}
  }
  return resp.Value{}
}

@(private)
read_string :: proc(s: ^store.Store, key: string) -> (resp.Value, bool) {
  value_ptr, ok := store.lookup(s, key)
  if !ok {
    return resp.null_bulk(), true
  }

  switch &value in value_ptr^ {
  case resp.Bulk_String, resp.Simple_String, resp.Integer:
    return value_as_bulk(value_ptr^), true
  case resp.Error, resp.Array:
    return wrongtype(), false
  }
  return wrongtype(), false
}

@(private)
reply_bytes :: proc(v: ^resp.Value) -> []u8 {
  switch &x in v^ {
  case resp.Bulk_String:
    if x.is_null {
      return nil
    }
    return x.items
  case resp.Simple_String:
    return x.items
  case resp.Integer, resp.Error, resp.Array:
    return nil
  }
  return nil
}

handle_get :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("get")
  }
  reply, ok := read_string(s, string(args[0].items))
  if !ok {
    return reply
  }
  return reply
}

handle_set :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 2 {
    return wrong_arity("set")
  }

  key := string(args[0].items)
  nx := false
  xx := false
  get := false
  keep_ttl := false
  ttl_mode := Set_TTL.None
  ttl_value: i64

  i := 2
  for i < len(args) {
    option := string(args[i].items)
    switch {
    case strings.equal_fold(option, "NX"):
      nx = true
      i += 1
    case strings.equal_fold(option, "XX"):
      xx = true
      i += 1
    case strings.equal_fold(option, "GET"):
      get = true
      i += 1
    case strings.equal_fold(option, "KEEPTTL"):
      if keep_ttl || ttl_mode != .None {
        return syntax_error()
      }
      keep_ttl = true
      i += 1
    case strings.equal_fold(option, "EX"),
         strings.equal_fold(option, "PX"),
         strings.equal_fold(option, "EXAT"),
         strings.equal_fold(option, "PXAT"):
      if keep_ttl || ttl_mode != .None || i + 1 >= len(args) {
        return syntax_error()
      }
      value, ok := parse_i64_arg(args[i + 1])
      if !ok {
        return integer_error()
      }
      if value <= 0 {
        return resp.error_from_string("ERR invalid expire time in 'set' command")
      }

      switch {
      case strings.equal_fold(option, "EX"):
        ttl_mode = .EX
      case strings.equal_fold(option, "PX"):
        ttl_mode = .PX
      case strings.equal_fold(option, "EXAT"):
        ttl_mode = .EXAT
      case strings.equal_fold(option, "PXAT"):
        ttl_mode = .PXAT
      }
      ttl_value = value
      i += 2
    case:
      return syntax_error()
    }
  }

  if nx && xx {
    return syntax_error()
  }

  _, exists := store.lookup(s, key)
  if (nx && exists) || (xx && !exists) {
    if get {
      old, ok := read_string(s, key)
      if !ok {
        return old
      }
      return old
    }
    return resp.null_bulk()
  }

  old_reply: resp.Value
  if get {
    old, ok := read_string(s, key)
    if !ok {
      return old
    }
    old_reply = old
  }

  new_value := bulk_from_string(string(args[1].items))
  store.put(s, key, &new_value, keep_ttl || ttl_mode == .KEEPTTL)

  if ttl_mode != .None && ttl_mode != .KEEPTTL {
    store.set_expiry_ms(s, key, ttl_millis(ttl_mode, ttl_value))
  }

  if get {
    return old_reply
  }
  return resp.simple_string_from_string("OK")
}

handle_append :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("append")
  }

  old, ok := read_string(s, string(args[0].items))
  if !ok {
    return old
  }
  defer resp.deinit_value(&old)

  old_bytes := reply_bytes(&old)
  value_bytes := args[1].items
  total := len(old_bytes) + len(value_bytes)
  items := make([]u8, total)
  copy(items, old_bytes)
  copy(items[len(old_bytes):], value_bytes)

  value: resp.Value = resp.Bulk_String{len = uint(total), items = items}
  store.put(s, string(args[0].items), &value, true)
  return resp.Integer{raw = i64(total)}
}

handle_strlen :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("strlen")
  }

  old, ok := read_string(s, string(args[0].items))
  if !ok {
    return old
  }
  defer resp.deinit_value(&old)
  return resp.Integer{raw = i64(len(reply_bytes(&old)))}
}

handle_incr :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("incr")
  }
  return store.incr(s, string(args[0].items))
}

handle_decr :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("decr")
  }
  return store.incr_by(s, string(args[0].items), -1)
}

handle_incrby :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("incrby")
  }
  amount, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  return store.incr_by(s, string(args[0].items), i128(amount))
}

handle_decrby :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("decrby")
  }
  amount, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  return store.incr_by(s, string(args[0].items), -i128(amount))
}

handle_incrbyfloat :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("incrbyfloat")
  }

  amount, ok := parse_f64_arg(args[1])
  if !ok {
    return float_error()
  }

  old, old_ok := read_string(s, string(args[0].items))
  if !old_ok {
    return old
  }
  defer resp.deinit_value(&old)

  base := f64(0)
  old_bytes := reply_bytes(&old)
  if len(old_bytes) != 0 {
    parsed, parsed_ok := strconv.parse_f64(string(old_bytes))
    if !parsed_ok {
      return float_error()
    }
    base = parsed
  }

  result := base + amount
  if math.is_nan(result) || math.is_inf(result, 0) {
    return resp.error_from_string("ERR increment would produce NaN or Infinity")
  }

  formatted := fmt.aprintf("%v", result)
  defer delete(formatted)

  value := bulk_from_string(formatted)
  store.put(s, string(args[0].items), &value, true)
  return bulk_from_string(formatted)
}

handle_getset :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("getset")
  }

  old, ok := read_string(s, string(args[0].items))
  if !ok {
    return old
  }

  value := bulk_from_string(string(args[1].items))
  store.put(s, string(args[0].items), &value, false)
  return old
}

handle_getdel :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("getdel")
  }

  old, ok := read_string(s, string(args[0].items))
  if !ok {
    return old
  }

  deleted := store.del(s, string(args[0].items))
  resp.deinit_value(&deleted)
  return old
}

handle_getrange :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("getrange")
  }

  start, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  stop, stop_ok := parse_i64_arg(args[2])
  if !stop_ok {
    return integer_error()
  }

  old, old_ok := read_string(s, string(args[0].items))
  if !old_ok {
    return old
  }
  defer resp.deinit_value(&old)

  data := reply_bytes(&old)
  first, last, valid := normalize_range(start, stop, len(data))
  if !valid {
    return resp.Bulk_String{len = 0, items = make([]u8, 0)}
  }
  return resp.Bulk_String{len = uint(last - first + 1), items = clone_bytes(data[first:last + 1])}
}

handle_setrange :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("setrange")
  }

  offset, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  if offset < 0 {
    return resp.error_from_string("ERR offset is out of range")
  }

  old, old_ok := read_string(s, string(args[0].items))
  if !old_ok {
    return old
  }
  defer resp.deinit_value(&old)

  old_bytes := reply_bytes(&old)
  value_bytes := args[2].items
  if len(value_bytes) == 0 {
    return resp.Integer{raw = i64(len(old_bytes))}
  }

  total := offset + i64(len(value_bytes))
  if offset > i64(max(int)) || total > i64(max(int)) {
    return resp.error_from_string("ERR offset is out of range")
  }

  items := make([]u8, int(total))
  copy(items, old_bytes)
  copy(items[int(offset):], value_bytes)

  value: resp.Value = resp.Bulk_String{len = uint(len(items)), items = items}
  store.put(s, string(args[0].items), &value, true)
  return resp.Integer{raw = i64(len(items))}
}

handle_mget :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) == 0 {
    return wrong_arity("mget")
  }

  items := make([]resp.Value, len(args))
  for arg, i in args {
    reply, ok := read_string(s, string(arg.items))
    if !ok {
      resp.deinit_value(&reply)
      items[i] = resp.null_bulk()
    } else {
      items[i] = reply
    }
  }
  return array_from_items(items)
}

handle_mset :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) == 0 || len(args) % 2 != 0 {
    return wrong_arity("mset")
  }

  for i := 0; i < len(args); i += 2 {
    value := bulk_from_string(string(args[i + 1].items))
    store.put(s, string(args[i].items), &value, false)
  }
  return resp.simple_string_from_string("OK")
}

handle_setex :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("setex")
  }

  seconds, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  if seconds <= 0 {
    return resp.error_from_string("ERR invalid expire time in 'setex' command")
  }

  value := bulk_from_string(string(args[2].items))
  store.put(s, string(args[0].items), &value, false)
  store.set_expiry_ms(s, string(args[0].items), ttl_millis(.EX, seconds))
  return resp.simple_string_from_string("OK")
}

handle_setnx :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("setnx")
  }

  if _, exists := store.lookup(s, string(args[0].items)); exists {
    return resp.Integer{raw = 0}
  }

  value := bulk_from_string(string(args[1].items))
  store.put(s, string(args[0].items), &value, false)
  return resp.Integer{raw = 1}
}
