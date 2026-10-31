package resp

import "core:strconv"

@(private)
append_crlf :: #force_inline proc(buf: ^[dynamic]u8) {
  append(buf, '\r', '\n')
}

@(private)
append_i64 :: #force_inline proc(buf: ^[dynamic]u8, value: i64) {
  tmp: [24]u8
  s := strconv.write_bits(tmp[:], u64(value), 10, true, 64, strconv.digits, nil)
  append(buf, s)
}

@(private)
append_uint :: #force_inline proc(buf: ^[dynamic]u8, value: uint) {
  tmp: [24]u8
  s := strconv.write_bits(tmp[:], u64(value), 10, false, 64, strconv.digits, nil)
  append(buf, s)
}

resp_write :: proc(buf: ^[dynamic]u8, v: Value) {
  switch x in v {
  case Simple_String:
    append(buf, '+')
    append(buf, ..x.items)
    append_crlf(buf)
  case Error:
    append(buf, '-')
    append(buf, ..x.body)
    append_crlf(buf)
  case Integer:
    append(buf, ':')
    append_i64(buf, x.raw)
    append_crlf(buf)
  case Bulk_String:
    if x.is_null {
      append(buf, '$', '-', '1')
      append_crlf(buf)
      return
    }
    append(buf, '$')
    append_uint(buf, uint(len(x.items)))
    append_crlf(buf)
    append(buf, ..x.items)
    append_crlf(buf)
  case Array:
    if x.is_null {
      append(buf, '*', '-', '1')
      append_crlf(buf)
      return
    }
    append(buf, '*')
    append_uint(buf, uint(len(x.items)))
    append_crlf(buf)
    for item in x.items {
      resp_write(buf, item)
    }
  }
}
