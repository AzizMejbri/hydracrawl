package command

import "core:slice"
import "core:strings"
import "core:time"
import green "../../green"
import resp "../../resp"
import store "../../store"

List_Side :: enum {
  Left,
  Right,
}

@(private)
null_array :: proc() -> resp.Value {
  return resp.Array{is_null = true}
}

@(private)
normalize_index :: proc(index: i64, length: int) -> (int, bool) {
  n := i64(length)
  i := index
  if i < 0 {
    i += n
  }
  if i < 0 || i >= n {
    return 0, false
  }
  return int(i), true
}

@(private)
get_list :: proc(s: ^store.Store, key: string) -> (^resp.Array, bool, bool) {
  value_ptr, ok := store.lookup(s, key)
  if !ok {
    return nil, false, false
  }

  switch &value in value_ptr^ {
  case resp.Array:
    return &value, true, false
  case resp.Bulk_String, resp.Simple_String, resp.Integer, resp.Error:
    return nil, true, true
  }
  return nil, true, true
}

@(private)
ensure_list :: proc(s: ^store.Store, key: string) -> (^resp.Array, bool, bool) {
  list, exists, wrong := get_list(s, key)
  if wrong || exists {
    return list, exists, wrong
  }

  empty: resp.Value = resp.Array{}
  store.put(s, key, &empty, false)
  list, _, wrong = get_list(s, key)
  return list, false, wrong
}

@(private)
list_cleanup_if_empty :: proc(s: ^store.Store, key: string, list: ^resp.Array) {
  if len(list.items) != 0 {
    return
  }
  reply := store.del(s, key)
  resp.deinit_value(&reply)
}

@(private)
list_remove_at :: proc(list: ^resp.Array, index: int) -> resp.Value {
  value := list.items[index]
  copy(list.items[index:], list.items[index + 1:])
  list.items = list.items[:len(list.items) - 1]
  list.len = uint(len(list.items))
  return value
}

@(private)
list_take :: proc(list: ^resp.Array, start, count: int) -> []resp.Value {
  removed := make([]resp.Value, count)
  copy(removed, list.items[start:start + count])
  copy(list.items[start:], list.items[start + count:])
  list.items = list.items[:len(list.items) - count]
  list.len = uint(len(list.items))
  return removed
}

@(private)
list_append_value :: proc(list: ^resp.Array, value: resp.Value) {
  items := make([]resp.Value, len(list.items) + 1)
  copy(items, list.items)
  items[len(list.items)] = value
  delete(list.items)
  list.items = items
  list.len = uint(len(items))
}

@(private)
list_prepend_value :: proc(list: ^resp.Array, value: resp.Value) {
  items := make([]resp.Value, len(list.items) + 1)
  items[0] = value
  copy(items[1:], list.items)
  delete(list.items)
  list.items = items
  list.len = uint(len(items))
}

@(private)
list_prepend_args :: proc(list: ^resp.Array, args: []resp.Bulk_String) {
  old_items := list.items
  items := make([]resp.Value, len(old_items) + len(args))
  for arg, i in args {
    items[len(args) - 1 - i] = bulk_from_string(string(arg.items))
  }
  copy(items[len(args):], old_items)
  delete(old_items)
  list.items = items
  list.len = uint(len(items))
}

@(private)
list_pop_one :: proc(s: ^store.Store, key: string, side: List_Side) -> (resp.Value, bool, bool) {
  list, exists, wrong := get_list(s, key)
  if wrong {
    return resp.Value{}, false, true
  }
  if !exists || len(list.items) == 0 {
    return resp.Value{}, false, false
  }

  index := 0
  if side == .Right {
    index = len(list.items) - 1
  }
  value := list_remove_at(list, index)
  list_cleanup_if_empty(s, key, list)
  return value, true, false
}

handle_lpush :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 2 {
    return wrong_arity("lpush")
  }

  list, _, wrong := ensure_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  list_prepend_args(list, args[1:])
  return resp.Integer{raw = i64(len(list.items))}
}

handle_rpush :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 2 {
    return wrong_arity("rpush")
  }

  list, _, wrong := ensure_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  for arg in args[1:] {
    list_append_value(list, bulk_from_string(string(arg.items)))
  }
  return resp.Integer{raw = i64(len(list.items))}
}

handle_lpop :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 1 || len(args) > 2 {
    return wrong_arity("lpop")
  }

  has_count := len(args) == 2
  count := 1
  if has_count {
    n, ok := parse_i64_arg(args[1])
    if !ok {
      return integer_error()
    }
    if n < 0 {
      return resp.error_from_string("ERR value is out of range, must be positive")
    }
    count = int(min(n, i64(max(int))))
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    if has_count {
      return null_array()
    }
    return resp.null_bulk()
  }

  if count > len(list.items) {
    count = len(list.items)
  }
  if count == 0 {
    if has_count {
      return array_from_items(make([]resp.Value, 0))
    }
    return resp.null_bulk()
  }

  if !has_count {
    value := list_remove_at(list, 0)
    list_cleanup_if_empty(s, string(args[0].items), list)
    return value
  }

  removed := list_take(list, 0, count)
  list_cleanup_if_empty(s, string(args[0].items), list)
  return array_from_items(removed)
}

handle_rpop :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 1 || len(args) > 2 {
    return wrong_arity("rpop")
  }

  has_count := len(args) == 2
  count := 1
  if has_count {
    n, ok := parse_i64_arg(args[1])
    if !ok {
      return integer_error()
    }
    if n < 0 {
      return resp.error_from_string("ERR value is out of range, must be positive")
    }
    count = int(min(n, i64(max(int))))
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    if has_count {
      return null_array()
    }
    return resp.null_bulk()
  }

  if count > len(list.items) {
    count = len(list.items)
  }
  if count == 0 {
    if has_count {
      return array_from_items(make([]resp.Value, 0))
    }
    return resp.null_bulk()
  }

  if !has_count {
    value := list_remove_at(list, len(list.items) - 1)
    list_cleanup_if_empty(s, string(args[0].items), list)
    return value
  }

  removed := list_take(list, len(list.items) - count, count)
  list_cleanup_if_empty(s, string(args[0].items), list)
  return array_from_items(removed)
}

handle_llen :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("llen")
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return resp.Integer{raw = 0}
  }
  return resp.Integer{raw = i64(len(list.items))}
}

handle_lrange :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("lrange")
  }

  start, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  stop, stop_ok := parse_i64_arg(args[2])
  if !stop_ok {
    return integer_error()
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return array_from_items(make([]resp.Value, 0))
  }

  first, last, valid := normalize_range(start, stop, len(list.items))
  if !valid {
    return array_from_items(make([]resp.Value, 0))
  }

  items := make([]resp.Value, last - first + 1)
  for item, i in list.items[first:last + 1] {
    items[i] = resp.init_value(item)
  }
  return array_from_items(items)
}

handle_lindex :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("lindex")
  }

  index, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return resp.null_bulk()
  }

  normalized, valid := normalize_index(index, len(list.items))
  if !valid {
    return resp.null_bulk()
  }
  return resp.init_value(list.items[normalized])
}

handle_linsert :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 4 {
    return wrong_arity("linsert")
  }

  before := false
  position := string(args[1].items)
  switch {
  case strings.equal_fold(position, "BEFORE"):
    before = true
  case strings.equal_fold(position, "AFTER"):
  case:
    return syntax_error()
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return resp.Integer{raw = 0}
  }

  pivot := args[2].items
  found := -1
  for item, i in list.items {
    bulk, bulk_ok := item.(resp.Bulk_String)
    if bulk_ok && !bulk.is_null && slice.equal(bulk.items, pivot) {
      found = i
      break
    }
  }
  if found < 0 {
    return resp.Integer{raw = -1}
  }

  insert_at := found
  if !before {
    insert_at += 1
  }

  items := make([]resp.Value, len(list.items) + 1)
  copy(items[:insert_at], list.items[:insert_at])
  items[insert_at] = bulk_from_string(string(args[3].items))
  copy(items[insert_at + 1:], list.items[insert_at:])
  delete(list.items)
  list.items = items
  list.len = uint(len(items))
  return resp.Integer{raw = i64(len(items))}
}

handle_lrem :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("lrem")
  }

  count, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return resp.Integer{raw = 0}
  }

  target := args[2].items
  removed := 0

  if count >= 0 {
    limit := count
    if limit == 0 {
      limit = i64(len(list.items))
    }
    write := 0
    for read in 0..<len(list.items) {
      item := &list.items[read]
      bulk, bulk_ok := item.(resp.Bulk_String)
      if i64(removed) < limit && bulk_ok && !bulk.is_null && slice.equal(bulk.items, target) {
        resp.deinit_value(item)
        removed += 1
      } else {
        if write != read {
          list.items[write] = list.items[read]
        }
        write += 1
      }
    }
    list.items = list.items[:write]
  } else {
    limit := -count
    write := len(list.items) - 1
    for read := len(list.items) - 1; read >= 0; read -= 1 {
      item := &list.items[read]
      bulk, bulk_ok := item.(resp.Bulk_String)
      if i64(removed) < limit && bulk_ok && !bulk.is_null && slice.equal(bulk.items, target) {
        resp.deinit_value(item)
        removed += 1
      } else {
        if write != read {
          list.items[write] = list.items[read]
        }
        write -= 1
      }
    }
    kept := len(list.items) - removed
    start := len(list.items) - kept
    list.items = list.items[start:start + kept]
  }

  list.len = uint(len(list.items))
  list_cleanup_if_empty(s, string(args[0].items), list)
  return resp.Integer{raw = i64(removed)}
}

handle_lset :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("lset")
  }

  index, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return resp.error_from_string("ERR no such key")
  }

  normalized, valid := normalize_index(index, len(list.items))
  if !valid {
    return resp.error_from_string("ERR index out of range")
  }

  resp.deinit_value(&list.items[normalized])
  list.items[normalized] = bulk_from_string(string(args[2].items))
  return resp.simple_string_from_string("OK")
}

handle_ltrim :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 3 {
    return wrong_arity("ltrim")
  }

  start, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }
  stop, stop_ok := parse_i64_arg(args[2])
  if !stop_ok {
    return integer_error()
  }

  list, exists, wrong := get_list(s, string(args[0].items))
  if wrong {
    return wrongtype()
  }
  if !exists {
    return resp.simple_string_from_string("OK")
  }

  first, last, valid := normalize_range(start, stop, len(list.items))
  if !valid {
    for &item in list.items {
      resp.deinit_value(&item)
    }
    list.items = list.items[:0]
    list.len = 0
    list_cleanup_if_empty(s, string(args[0].items), list)
    return resp.simple_string_from_string("OK")
  }

  kept := last - first + 1
  items := make([]resp.Value, kept)
  for item, i in list.items {
    if i >= first && i <= last {
      items[i - first] = item
    } else {
      value := &list.items[i]
      resp.deinit_value(value)
    }
  }
  delete(list.items)
  list.items = items
  list.len = uint(len(items))
  return resp.simple_string_from_string("OK")
}

handle_blpop :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  return blocking_pop(s, args, .Left, "blpop")
}

handle_brpop :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  return blocking_pop(s, args, .Right, "brpop")
}

@(private)
blocking_pop :: proc(
  s: ^store.Store,
  args: []resp.Bulk_String,
  side: List_Side,
  name: string,
) -> resp.Value {
  if len(args) < 2 {
    return wrong_arity(name)
  }

  timeout, ok := parse_f64_arg(args[len(args) - 1])
  if !ok {
    return resp.error_from_string("ERR timeout is not a float or out of range")
  }
  if timeout < 0 {
    return resp.error_from_string("ERR timeout is negative")
  }

  has_deadline := timeout > 0
  deadline: i64
  if has_deadline {
    if timeout > f64(max(i64)) / 1_000_000_000 {
      deadline = max(i64)
    } else {
      nanos := i64(timeout * 1_000_000_000)
      deadline = time.time_to_unix_nano(time.now()) + nanos
    }
  }

  for {
    for key_arg in args[:len(args) - 1] {
      key := string(key_arg.items)
      value, found, wrong := list_pop_one(s, key, side)
      if wrong {
        return wrongtype()
      }
      if found {
        items := make([]resp.Value, 2)
        items[0] = bulk_from_string(key)
        items[1] = value
        return array_from_items(items)
      }
    }

    sleep_ns: i64 = 10_000_000
    if has_deadline {
      remaining := deadline - time.time_to_unix_nano(time.now())
      if remaining <= 0 {
        return null_array()
      }
      if remaining < sleep_ns {
        sleep_ns = remaining
      }
    }
    params: green.Request_Params = green.Timeout_Params{ns = uint(sleep_ns)}
    green.request(&params)
  }
}

handle_lmove :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 4 {
    return wrong_arity("lmove")
  }

  source_side: List_Side
  dest_side: List_Side
  switch {
  case strings.equal_fold(string(args[2].items), "LEFT"):
    source_side = .Left
  case strings.equal_fold(string(args[2].items), "RIGHT"):
    source_side = .Right
  case:
    return syntax_error()
  }
  switch {
  case strings.equal_fold(string(args[3].items), "LEFT"):
    dest_side = .Left
  case strings.equal_fold(string(args[3].items), "RIGHT"):
    dest_side = .Right
  case:
    return syntax_error()
  }

  source_key := string(args[0].items)
  dest_key := string(args[1].items)

  source, source_exists, source_wrong := get_list(s, source_key)
  if source_wrong {
    return wrongtype()
  }
  if !source_exists || len(source.items) == 0 {
    return resp.null_bulk()
  }

  same_list := source_key == dest_key
  if !same_list {
    _, _, dest_wrong := get_list(s, dest_key)
    if dest_wrong {
      return wrongtype()
    }
  }

  source_index := 0
  if source_side == .Right {
    source_index = len(source.items) - 1
  }
  value := list_remove_at(source, source_index)
  reply := resp.init_value(value)

  if same_list {
    if dest_side == .Left {
      list_prepend_value(source, value)
    } else {
      list_append_value(source, value)
    }
    return reply
  }

  list_cleanup_if_empty(s, source_key, source)
  dest, _, dest_wrong := ensure_list(s, dest_key)
  if dest_wrong {
    resp.deinit_value(&reply)
    resp.deinit_value(&value)
    return wrongtype()
  }
  if dest_side == .Left {
    list_prepend_value(dest, value)
  } else {
    list_append_value(dest, value)
  }
  return reply
}
