package command

import "core:fmt"
import "core:strconv"
import resp "../../resp"

// Helpers used by command handlers across more than one category
// (connection/strings/lists/keys) -- anything used by only one category
// lives alongside its handlers in that category's own file instead.

// Own copy of dispatch.odin's errorf: command can't import server (that
// would be circular, since server imports command) and this is too
// small to be worth a shared third package for.
@(private)
errorf :: proc(format: string, args: ..any) -> resp.Value {
  msg := fmt.aprintf(format, ..args)
  defer delete(msg)
  return resp.error_from_string(msg)
}

@(private)
wrong_arity :: proc(name: string) -> resp.Value {
  return errorf("ARITY_ERROR wrong number of arguments for '%s' command", name)
}

@(private)
clone_bytes :: proc(src: []u8) -> []u8 {
  if src == nil {
    return nil
  }
  dst := make([]u8, len(src))
  copy(dst, src)
  return dst
}

@(private)
bulk_from_string :: proc(s: string) -> resp.Value {
  return resp.Bulk_String{len = uint(len(s)), items = clone_bytes(transmute([]u8)s)}
}

@(private)
bulk_from_int :: proc(n: i64) -> resp.Value {
  s := fmt.aprintf("%d", n)
  defer delete(s)
  return bulk_from_string(s)
}

@(private)
array_from_items :: proc(items: []resp.Value, is_null := false) -> resp.Value {
  return resp.Array{is_null = is_null, len = uint(len(items)), items = items}
}

@(private)
wrongtype :: proc() -> resp.Value {
  return resp.error_from_string("WRONGTYPE Operation against a key holding the wrong kind of value")
}

@(private)
syntax_error :: proc() -> resp.Value {
  return resp.error_from_string("ERR syntax error")
}

@(private)
integer_error :: proc() -> resp.Value {
  return resp.error_from_string("ERR value is not an integer or out of range")
}

@(private)
parse_i64_arg :: proc(arg: resp.Bulk_String) -> (i64, bool) {
  return strconv.parse_i64_of_base(string(arg.items), 10)
}

@(private)
parse_f64_arg :: proc(arg: resp.Bulk_String) -> (f64, bool) {
  return strconv.parse_f64(string(arg.items))
}

// first/last range-normalization shared by GETRANGE (strings) and
// LRANGE/LTRIM (lists) -- clamps/negative-indexes start/stop against
// length the same way for both.
@(private)
normalize_range :: proc(start, stop: i64, length: int) -> (int, int, bool) {
  if length == 0 {
    return 0, -1, false
  }

  n := i64(length)
  first := start
  last := stop
  if first < 0 {
    first += n
  }
  if last < 0 {
    last += n
  }
  if first < 0 {
    first = 0
  }
  if last < 0 || first >= n || first > last {
    return 0, -1, false
  }
  if last >= n {
    last = n - 1
  }
  return int(first), int(last), true
}
