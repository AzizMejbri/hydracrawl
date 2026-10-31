package store

import "core:mem"
import "core:strconv"
import "core:strings"
import "core:time"
import resp "../resp"

Store :: struct {
  raw: map[string]resp.Value,
  expiry: map[string]u64, // absolute unix milliseconds
  // fixed at store_init time, independent of whatever context.allocator
  // a caller happens to be running under (e.g. a connection fiber's
  // per-round arena) -- everything actually persisted into raw/expiry
  // must outlive any single connection, so it can't ride that caller's
  // allocator. A read that returns a fresh copy to the caller (get) is
  // the opposite case and intentionally keeps using the caller's own
  // ambient allocator instead.
  allocator: mem.Allocator,
}

Expire_Option :: enum {
  None,
  NX,
  XX,
  GT,
  LT,
}

@(private)
now_millis :: proc() -> u64 {
  nanos := time.time_to_unix_nano(time.now())
  if nanos <= 0 {
    return 0
  }
  return u64(nanos / 1_000_000)
}

// Everything below that frees or clones something stored in raw/expiry
// swaps context.allocator to s.allocator for its own body first -- those
// bytes were (or are about to be) persisted independent of whatever
// allocator the caller happens to be running under, so freeing/cloning
// them must go through the same allocator they were created with,
// regardless of call site.

@(private)
clear_expiry :: proc(s: ^Store, key: string) {
  prev := context.allocator
  context.allocator = s.allocator
  defer context.allocator = prev

  deleted_key, _ := delete_key(&s.expiry, key)
  delete(deleted_key)
}

@(private)
remove_key :: proc(s: ^Store, key: string) -> bool {
  prev := context.allocator
  context.allocator = s.allocator
  defer context.allocator = prev

  if _, ok := s.raw[key]; !ok {
    clear_expiry(s, key)
    return false
  }

  deleted_key, value := delete_key(&s.raw, key)
  resp.deinit_value(&value)
  delete(deleted_key)
  clear_expiry(s, key)
  return true
}

@(private)
is_expired :: proc(s: ^Store, key: string) -> bool {
  expiry, ok := s.expiry[key]
  if !ok {
    return false
  }
  if expiry <= now_millis() {
    remove_key(s, key)
    return true
  }
  return false
}

@(private)
wrongtype :: proc() -> resp.Value {
  return resp.error_from_string("WRONGTYPE Operation against a key holding the wrong kind of value")
}

@(private)
not_integer :: proc() -> resp.Value {
  return resp.error_from_string("ERR value is not an integer or out of range")
}

store_init :: proc(s: ^Store, allocator := context.allocator) {
  s.allocator = allocator
  s.raw = make(map[string]resp.Value, allocator = s.allocator)
  s.expiry = make(map[string]u64, allocator = s.allocator)
}

store_deinit :: proc(s: ^Store) {
  prev := context.allocator
  context.allocator = s.allocator
  defer context.allocator = prev

  for _, value in s.raw {
    v := value
    resp.deinit_value(&v)
  }
  for key in s.raw {
    delete(key)
  }
  delete(s.raw)

  for key in s.expiry {
    delete(key)
  }
  delete(s.expiry)

  s.raw = nil
  s.expiry = nil
}

// lookup returns a pointer to the live value for key. The pointer is only
// valid until the next insertion/removal in the map.
lookup :: proc(s: ^Store, key: string) -> (^resp.Value, bool) {
  if is_expired(s, key) {
    return nil, false
  }
  if _, ok := s.raw[key]; !ok {
    return nil, false
  }

  _, value_ptr, _, err := map_entry(&s.raw, key)
  ensure(err == nil, "Store: failed to grow the store map")
  return value_ptr, true
}

// put transfers ownership of value into the store and clears value.
// value itself must already be allocated with s.allocator (or own no
// bytes at all, e.g. a plain Integer) -- put only clones/frees the key
// and any old value it overwrites, not value itself.
put :: proc(s: ^Store, key: string, value: ^resp.Value, keep_ttl: bool) {
  if value == nil {
    return
  }

  prev := context.allocator
  context.allocator = s.allocator
  defer context.allocator = prev

  key_ptr, value_ptr, inserted, err := map_entry(&s.raw, key)
  ensure(err == nil, "Store: failed to grow the store map")

  if value_ptr == value {
    return
  }

  if inserted {
    key_clone, clone_err := strings.clone(key)
    ensure(clone_err == nil, "Store: failed to clone the key")
    key_ptr^ = key_clone
  } else {
    resp.deinit_value(value_ptr)
  }

  value_ptr^ = value^
  value^ = nil

  if !keep_ttl {
    clear_expiry(s, key)
  }
}

get :: proc(s: ^Store, key: string) -> resp.Value {
  value_ptr, ok := lookup(s, key)
  if !ok {
    return resp.null_bulk()
  }
  return resp.init_value(value_ptr^)
}

set :: proc(s: ^Store, key: string, value: resp.Value) -> resp.Value {
  // stored must survive past this connection, so it's cloned with
  // s.allocator, not whatever the caller's ambient context.allocator is
  // -- restored before building the reply below, which is transient and
  // should stay on the caller's own allocator (e.g. its connection arena)
  prev := context.allocator
  context.allocator = s.allocator
  stored := resp.init_value(value)
  put(s, key, &stored, false)
  context.allocator = prev

  return resp.simple_string_from_string("OK")
}

del :: proc(s: ^Store, key: string) -> resp.Value {
  if is_expired(s, key) {
    return resp.Integer{raw = 0}
  }
  if remove_key(s, key) {
    return resp.Integer{raw = 1}
  }
  return resp.Integer{raw = 0}
}

exists :: proc(s: ^Store, key: string) -> resp.Value {
  if _, ok := lookup(s, key); ok {
    return resp.Integer{raw = 1}
  }
  return resp.Integer{raw = 0}
}

incr_by :: proc(s: ^Store, key: string, delta: i128) -> resp.Value {
  value_ptr, ok := lookup(s, key)
  if !ok {
    if delta < i128(min(i64)) || delta > i128(max(i64)) {
      return resp.error_from_string("ERR increment or decrement would overflow")
    }
    value: resp.Value = resp.Integer{raw = i64(delta)}
    put(s, key, &value, false)
    return resp.Integer{raw = i64(delta)}
  }

  base: i128
  switch &old in value_ptr^ {
  case resp.Integer:
    base = i128(old.raw)
  case resp.Bulk_String:
    if old.is_null {
      return not_integer()
    }
    parsed, parsed_ok := strconv.parse_i64(string(old.items))
    if !parsed_ok {
      return not_integer()
    }
    base = i128(parsed)
  case resp.Simple_String:
    parsed, parsed_ok := strconv.parse_i64(string(old.items))
    if !parsed_ok {
      return not_integer()
    }
    base = i128(parsed)
  case resp.Error, resp.Array:
    return wrongtype()
  }

  next := base + delta
  if next < i128(min(i64)) || next > i128(max(i64)) {
    return resp.error_from_string("ERR increment or decrement would overflow")
  }

  value: resp.Value = resp.Integer{raw = i64(next)}
  put(s, key, &value, true)
  return resp.Integer{raw = i64(next)}
}

incr :: proc(s: ^Store, key: string) -> resp.Value {
  return incr_by(s, key, 1)
}

ttl :: proc(s: ^Store, key: string) -> resp.Value {
  if is_expired(s, key) {
    return resp.Integer{raw = -2}
  }
  if _, ok := s.raw[key]; !ok {
    return resp.Integer{raw = -2}
  }

  expiry, ok := s.expiry[key]
  if !ok {
    return resp.Integer{raw = -1}
  }

  now := now_millis()
  if expiry <= now {
    remove_key(s, key)
    return resp.Integer{raw = -2}
  }
  return resp.Integer{raw = i64((expiry - now) / 1000)}
}

set_expiry_ms :: proc(s: ^Store, key: string, expires_at_ms: u64) -> bool {
  if is_expired(s, key) {
    return false
  }
  if _, ok := s.raw[key]; !ok {
    return false
  }

  if expires_at_ms <= now_millis() {
    remove_key(s, key)
    return true
  }

  prev := context.allocator
  context.allocator = s.allocator
  defer context.allocator = prev

  key_ptr, value_ptr, inserted, err := map_entry(&s.expiry, key)
  ensure(err == nil, "Store: failed to grow the expiry map")

  if inserted {
    key_clone, clone_err := strings.clone(key)
    ensure(clone_err == nil, "Store: failed to clone the key")
    key_ptr^ = key_clone
  }

  value_ptr^ = expires_at_ms
  return true
}

expiry_ms :: proc(s: ^Store, key: string) -> (u64, bool) {
  if is_expired(s, key) {
    return 0, false
  }
  expiry, ok := s.expiry[key]
  return expiry, ok
}

expire_seconds_opt :: proc(
  s: ^Store,
  key: string,
  seconds: i64,
  option: Expire_Option = .None,
) -> bool {
  if is_expired(s, key) {
    return false
  }
  if _, ok := s.raw[key]; !ok {
    return false
  }

  current, has_expiry := s.expiry[key]
  now := now_millis()

  expires_at: u64
  if seconds <= 0 {
    expires_at = 0
  } else {
    seconds_u := u64(seconds)
    if seconds_u > (max(u64) - now) / 1000 {
      expires_at = max(u64)
    } else {
      expires_at = now + seconds_u * 1000
    }
  }

  switch option {
  case .None:
  case .NX:
    if has_expiry {
      return false
    }
  case .XX:
    if !has_expiry {
      return false
    }
  case .GT:
    if !has_expiry || expires_at <= current {
      return false
    }
  case .LT:
    if has_expiry && expires_at >= current {
      return false
    }
  }

  if seconds <= 0 {
    remove_key(s, key)
    return true
  }

  set_expiry_ms(s, key, expires_at)
  return true
}

expire :: proc(s: ^Store, key: string, seconds: i64) -> resp.Value {
  return resp.Integer{raw = expire_seconds_opt(s, key, seconds) ? 1 : 0}
}

persist :: proc(s: ^Store, key: string) -> bool {
  if is_expired(s, key) {
    return false
  }
  if _, ok := s.raw[key]; !ok {
    return false
  }
  if _, ok := s.expiry[key]; !ok {
    return false
  }
  clear_expiry(s, key)
  return true
}

rename :: proc(s: ^Store, old_key: string, new_key: string) -> bool {
  old_value_ptr, ok := lookup(s, old_key)
  if !ok {
    return false
  }
  if old_key == new_key {
    return true
  }

  old_expiry, had_expiry := s.expiry[old_key]
  old_value := old_value_ptr^

  prev := context.allocator
  context.allocator = s.allocator
  deleted_key, _ := delete_key(&s.raw, old_key)
  delete(deleted_key)
  context.allocator = prev
  clear_expiry(s, old_key)

  moved := old_value
  put(s, new_key, &moved, false)
  if had_expiry {
    set_expiry_ms(s, new_key, old_expiry)
  }
  return true
}

// keys returns a slice of live key strings. The strings are owned by the
// store; the caller owns only the returned slice.
keys :: proc(s: ^Store) -> []string {
  all: [dynamic]string
  for key in s.raw {
    append(&all, key)
  }

  live: [dynamic]string
  for key in all {
    if !is_expired(s, key) {
      append(&live, key)
    }
  }

  delete(all)
  return live[:]
}

type_name :: proc(s: ^Store, key: string) -> string {
  value_ptr, ok := lookup(s, key)
  if !ok {
    return "none"
  }

  switch &value in value_ptr^ {
  case resp.Array:
    return "list"
  case resp.Bulk_String, resp.Simple_String, resp.Integer, resp.Error:
    return "string"
  }

  return "none"
}
