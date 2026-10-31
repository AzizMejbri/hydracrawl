package resp

Bulk_String :: struct {
  is_null: bool,
  len: uint,
  items: []u8
}

Simple_String :: struct {
  len: uint,
  items: []u8
}

Integer :: struct {
  raw: i64
}

Error :: struct {
  body: []u8,
  kind_len: uint,
}

Array :: struct {
  is_null: bool,
  len: uint,
  items: []Value
}

Value :: union {
  // RESP2 Values
  Bulk_String,
  Simple_String,
  Integer,
  Error,
  Array,
  // TODO: RESP3 values
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

init_value :: proc(v: Value) -> Value {
  switch x in v {
  case Bulk_String:
    return Bulk_String{is_null = x.is_null, len = x.len, items = clone_bytes(x.items)}
  case Simple_String:
    return Simple_String{len = x.len, items = clone_bytes(x.items)}
  case Integer:
    return Integer{raw = x.raw}
  case Error:
    return Error{body = clone_bytes(x.body), kind_len = x.kind_len}
  case Array:
    items: []Value
    if x.items != nil {
      items = make([]Value, len(x.items))
      for item, i in x.items {
        items[i] = init_value(item)
      }
    }
    return Array{is_null = x.is_null, len = x.len, items = items}
  }
  return nil
}

deinit_value :: proc(v: ^Value) {
  if v == nil {
    return
  }

  switch &x in v^ {
  case Bulk_String:
    delete(x.items)
    x.items = nil
  case Simple_String:
    delete(x.items)
    x.items = nil
  case Integer:
  case Error:
    delete(x.body)
    x.body = nil
  case Array:
    for &item in x.items {
      deinit_value(&item)
    }
    delete(x.items)
    x.items = nil
  }

  v^ = nil
}

make_error :: proc(body: []u8) -> Error {
  kind_len := uint(len(body))
  for i in 0..<len(body) {
    if body[i] == ' ' {
      kind_len = uint(i)
      break
    }
  }
  return Error{body = body, kind_len = kind_len}
}

error_kind :: proc(e: Error) -> []u8 {
  return e.body[:e.kind_len]
}

error_msg :: proc(e: Error) -> []u8 {
  if e.kind_len < len(e.body) {
    return e.body[e.kind_len + 1:]
  }
  return nil
}

error_len :: proc(e: Error) -> uint {
  return uint(len(e.body))
}

simple_string_from_string :: proc(s: string) -> Simple_String {
  items := clone_bytes(transmute([]u8)s)
  return Simple_String{len = uint(len(items)), items = items}
}

error_from_string :: proc(s: string) -> Error {
  body := clone_bytes(transmute([]u8)s)
  return make_error(body)
}

null_bulk :: proc() -> Bulk_String {
  return Bulk_String{is_null = true}
}
