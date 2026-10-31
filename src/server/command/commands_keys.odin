package command

import "core:slice"
import "core:strings"
import "core:time"
import resp "../../resp"
import store "../../store"

@(private)
parse_expire_option :: proc(arg: resp.Bulk_String) -> (store.Expire_Option, bool) {
  option := string(arg.items)
  switch {
  case strings.equal_fold(option, "NX"):
    return .NX, true
  case strings.equal_fold(option, "XX"):
    return .XX, true
  case strings.equal_fold(option, "GT"):
    return .GT, true
  case strings.equal_fold(option, "LT"):
    return .LT, true
  }
  return .None, false
}

@(private)
glob_match_from :: proc(pattern: string, pi: int, text: string, ti: int) -> bool {
  if pi >= len(pattern) {
    return ti >= len(text)
  }

  switch pattern[pi] {
  case '*':
    for i in ti..=len(text) {
      if glob_match_from(pattern, pi + 1, text, i) {
        return true
      }
    }
    return false
  case '?':
    return ti < len(text) && glob_match_from(pattern, pi + 1, text, ti + 1)
  case '[':
    if ti >= len(text) {
      return false
    }

    end := pi + 1
    negate := false
    if end < len(pattern) && (pattern[end] == '^' || pattern[end] == '!') {
      negate = true
      end += 1
    }

    matched := false
    first := true
    for end < len(pattern) && (pattern[end] != ']' || first) {
      first = false
      low := pattern[end]
      high := low
      if end + 2 < len(pattern) && pattern[end + 1] == '-' && pattern[end + 2] != ']' {
        high = pattern[end + 2]
        end += 2
      }
      if text[ti] >= low && text[ti] <= high {
        matched = true
      }
      end += 1
    }

    if end >= len(pattern) {
      return text[ti] == '[' && glob_match_from(pattern, pi + 1, text, ti + 1)
    }
    if negate {
      matched = !matched
    }
    if !matched {
      return false
    }
    return glob_match_from(pattern, end + 1, text, ti + 1)
  case '\\':
    if pi + 1 < len(pattern) {
      return ti < len(text) && text[ti] == pattern[pi + 1] && glob_match_from(pattern, pi + 2, text, ti + 1)
    }
    return ti < len(text) && text[ti] == '\\' && glob_match_from(pattern, pi + 1, text, ti + 1)
  case:
    return ti < len(text) && text[ti] == pattern[pi] && glob_match_from(pattern, pi + 1, text, ti + 1)
  }
  return false
}

@(private)
glob_match :: proc(pattern, text: string) -> bool {
  return glob_match_from(pattern, 0, text, 0)
}

handle_del :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) == 0 {
    return wrong_arity("del")
  }
  removed: i64
  for arg in args {
    reply := store.del(s, string(arg.items))
    if n, ok := reply.(resp.Integer); ok {
      removed += n.raw
    }
    resp.deinit_value(&reply)
  }
  return resp.Integer{raw = removed}
}

handle_exists :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) == 0 {
    return wrong_arity("exists")
  }
  found: i64
  for arg in args {
    reply := store.exists(s, string(arg.items))
    if n, ok := reply.(resp.Integer); ok {
      found += n.raw
    }
    resp.deinit_value(&reply)
  }
  return resp.Integer{raw = found}
}

handle_expire :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 2 || len(args) > 3 {
    return wrong_arity("expire")
  }

  seconds, ok := parse_i64_arg(args[1])
  if !ok {
    return integer_error()
  }

  option := store.Expire_Option.None
  if len(args) == 3 {
    parsed, parsed_ok := parse_expire_option(args[2])
    if !parsed_ok {
      return syntax_error()
    }
    option = parsed
  }

  return resp.Integer{raw = store.expire_seconds_opt(s, string(args[0].items), seconds, option) ? 1 : 0}
}

handle_ttl :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("ttl")
  }
  return store.ttl(s, string(args[0].items))
}

handle_persist :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("persist")
  }
  return resp.Integer{raw = store.persist(s, string(args[0].items)) ? 1 : 0}
}

handle_type :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("type")
  }
  return bulk_from_string(store.type_name(s, string(args[0].items)))
}

handle_keys :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("keys")
  }

  pattern := string(args[0].items)
  live := store.keys(s)
  defer delete(live)

  matched: [dynamic]string
  defer delete(matched)
  for key in live {
    if glob_match(pattern, key) {
      append(&matched, key)
    }
  }

  slice.sort(matched[:])
  items := make([]resp.Value, len(matched))
  for key, i in matched {
    items[i] = bulk_from_string(key)
  }
  return array_from_items(items)
}

handle_scan :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) < 1 {
    return wrong_arity("scan")
  }

  cursor, ok := parse_i64_arg(args[0])
  if !ok || cursor < 0 {
    return resp.error_from_string("ERR invalid cursor")
  }

  pattern := "*"
  count: i64 = 10
  type_filter := ""
  i := 1
  for i < len(args) {
    option := string(args[i].items)
    switch {
    case strings.equal_fold(option, "MATCH"):
      if i + 1 >= len(args) {
        return syntax_error()
      }
      pattern = string(args[i + 1].items)
      i += 2
    case strings.equal_fold(option, "COUNT"):
      if i + 1 >= len(args) {
        return syntax_error()
      }
      parsed, parsed_ok := parse_i64_arg(args[i + 1])
      if !parsed_ok || parsed <= 0 {
        return syntax_error()
      }
      count = parsed
      i += 2
    case strings.equal_fold(option, "TYPE"):
      if i + 1 >= len(args) {
        return syntax_error()
      }
      type_filter = string(args[i + 1].items)
      i += 2
    case:
      return syntax_error()
    }
  }

  live := store.keys(s)
  defer delete(live)

  matched: [dynamic]string
  defer delete(matched)
  for key in live {
    if !glob_match(pattern, key) {
      continue
    }
    if len(type_filter) != 0 && store.type_name(s, key) != type_filter {
      continue
    }
    append(&matched, key)
  }
  slice.sort(matched[:])

  start := int(min(cursor, i64(len(matched))))
  end := start + int(min(count, i64(len(matched) - start)))
  next_cursor := 0
  if end < len(matched) {
    next_cursor = end
  }

  items := make([]resp.Value, 2)
  items[0] = bulk_from_int(i64(next_cursor))
  keys := make([]resp.Value, end - start)
  for key, j in matched[start:end] {
    keys[j] = bulk_from_string(key)
  }
  items[1] = array_from_items(keys)
  return array_from_items(items)
}

handle_rename :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 2 {
    return wrong_arity("rename")
  }
  if !store.rename(s, string(args[0].items), string(args[1].items)) {
    return resp.error_from_string("ERR no such key")
  }
  return resp.simple_string_from_string("OK")
}

handle_randomkey :: proc(s: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 0 {
    return wrong_arity("randomkey")
  }

  live := store.keys(s)
  defer delete(live)
  if len(live) == 0 {
    return resp.null_bulk()
  }

  nanos := time.time_to_unix_nano(time.now())
  index := int(nanos % i64(len(live)))
  if index < 0 {
    index = -index
  }
  return bulk_from_string(live[index])
}
