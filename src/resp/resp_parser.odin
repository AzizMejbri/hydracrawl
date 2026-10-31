package resp

// TODO:
// - RESP parser only parses according to RESP2, this is by design
// PERF:
// - RESP parser uses combinational parsers, which is less efficient than
//   hand-written parsers, this tradeoff is known and is a dev speed sacrifice by
//   design, later optimizations will involve hand-rolling the parser

Term :: struct {}

terminator :: proc() -> Parser(u8, Term) {
  return parser_map(then_ignore(just(byte('\r')), just(byte('\n'))), 
    proc(_: u8) -> Term { return Term{}; })
}

@(private)
crlf_at :: proc(input: []u8, idx: uint) -> bool {
  return idx + 1 < uint(len(input)) && input[idx] == '\r' && input[idx + 1] == '\n'
}

@(private)
scan_u64 :: proc(input: []u8, start: uint) -> (value: u64, end: uint, ok: bool) {
  i := start
  input_len := uint(len(input))
  if i >= input_len {
    return 0, start, false
  }
  c := input[i]
  if c < '0' || c > '9' {
    return 0, start, false
  }

  n: u64
  for i < input_len {
    c = input[i]
    if c < '0' || c > '9' {
      break
    }
    d := u64(c - '0')
    if n > (max(u64) - d) / 10 {
      return 0, start, false
    }
    n = n * 10 + d
    i += 1
  }
  return n, i, true
}

// line_p consumes a CRLF-terminated line and returns a copy of its body.
// RESP2 Simple Strings and Errors both allow any byte except CR and LF.
line_p :: proc() -> Parser(u8, []u8) {
  result: Parser(u8, []u8)
  result.destroy = proc(_: rawptr) {}
  result.run = proc(_: rawptr, input: []u8, ps: ^Parser_State) -> ([]u8, bool) {
    start := ps.idx
    input_len := uint(len(input))
    i := start
    for i < input_len {
      c := input[i]
      if c == '\n' {
        error("line_p: bare LF", ps)
        return nil, false
      }
      if c == '\r' {
        if i + 1 >= input_len || input[i + 1] != '\n' {
          error("line_p: CR not followed by LF", ps)
          return nil, false
        }
        body := make([]u8, i - start)
        copy(body, input[start:i])
        ps.idx = i + 2
        return body, true
      }
      i += 1
    }
    error("line_p: not enough input", ps)
    return nil, false
  }
  return result
}

error_p :: proc() -> Parser(u8, Error) {
  return parser_map(
    ignore_then(just(byte('-')), line_p()),
    proc(body: []u8) -> Error {
      return make_error(body)
    },
  )
}

take_bytes_p :: proc(n: uint) -> Parser(u8, []u8) {
  return take_p(n, u8)
}

simple_string_p :: proc() -> Parser(u8, Simple_String) {
  return parser_map(
    ignore_then(just(byte('+')), line_p()),
    proc(items: []u8) -> Simple_String {
      return Simple_String{ len = uint(len(items)), items = items }
    },
  )
}

length_p :: proc() -> Parser(u8, Maybe(uint)) {
  result: Parser(u8, Maybe(uint))
  result.destroy = proc(_: rawptr) {}
  result.run = proc(_: rawptr, input: []u8, ps: ^Parser_State) -> (Maybe(uint), bool) {
    i := ps.idx
    input_len := uint(len(input))
    negative := false

    if i < input_len && input[i] == '-' {
      negative = true
      i += 1
    }

    value, end, ok := scan_u64(input, i)
    if !ok {
      error("length_p: invalid length", ps)
      return nil, false
    }
    if negative {
      if value != 1 || end != i + 1 {
        error("length_p: only -1 is a valid null length", ps)
        return nil, false
      }
      ps.idx = end
      return nil, true
    }

    if value > u64(max(uint)) {
      error("length_p: length does not fit in uint", ps)
      return nil, false
    }

    ps.idx = end
    return uint(value), true
  }
  return result
}

bulk_string_p :: proc() -> Parser(u8, Bulk_String) {
  header := then_ignore(
    ignore_then(just(byte('$')), length_p()),
    terminator(),
  )
  return bind(header, proc(n: Maybe(uint)) -> Parser(u8, Bulk_String) {
    if count, ok := n.?; ok {
      return parser_map(
        then_ignore(take_bytes_p(count), terminator()),
        proc(data: []u8) -> Bulk_String {
          return Bulk_String{ len = uint(len(data)), items = data }
        },
      )
    }
    null_bulk_value: Bulk_String
    null_bulk_value.is_null = true
    return succeed_p(null_bulk_value, u8)
  })
}

integer_p :: proc() -> Parser(u8, Integer) {
  result: Parser(u8, Integer)
  result.destroy = proc(_: rawptr) {}
  result.run = proc(_: rawptr, input: []u8, ps: ^Parser_State) -> (Integer, bool) {
    start := ps.idx
    input_len := uint(len(input))
    i := start

    if i >= input_len || input[i] != ':' {
      error("integer_p: expected ':'", ps)
      return {}, false
    }
    i += 1

    negative := false
    if i < input_len && input[i] == '-' {
      negative = true
      i += 1
    }

    value, end, ok := scan_u64(input, i)
    if !ok {
      error("integer_p: invalid integer", ps)
      return {}, false
    }
    if !crlf_at(input, end) {
      error("integer_p: expected CRLF", ps)
      return {}, false
    }

    raw: i64
    if negative {
      limit := u64(1) << 63
      if value > limit {
        error("integer_p: integer underflow", ps)
        return {}, false
      }
      if value == limit {
        raw = min(i64)
      } else {
        raw = -i64(value)
      }
    } else {
      if value > u64(max(i64)) {
        error("integer_p: integer overflow", ps)
        return {}, false
      }
      raw = i64(value)
    }

    ps.idx = end + 2
    return Integer{ raw = raw }, true
  }
  return result
}

array_p :: proc() -> Parser(u8, Array) {
  header := then_ignore(
    ignore_then(just(byte('*')), length_p()),
    terminator(),
  )
  return bind(header, proc(n: Maybe(uint)) -> Parser(u8, Array) {
    if count, ok := n.?; ok {
      return parser_map(
        count_p(value_p(), count),
        proc(items: []Value) -> Array {
          return Array{ len = uint(len(items)), items = items }
        },
      )
    }
    null_array: Array
    null_array.is_null = true
    return succeed_p(null_array, u8)
  })
}

value_p :: proc() -> Parser(u8, Value) {
  return alt(
    parser_map(simple_string_p(), proc(v: Simple_String) -> Value { return v }),
    alt(
      parser_map(error_p(), proc(v: Error) -> Value { return v }),
      alt(
        parser_map(integer_p(), proc(v: Integer) -> Value { return v }),
        alt(
          parser_map(bulk_string_p(), proc(v: Bulk_String) -> Value { return v }),
          parser_map(array_p(), proc(v: Array) -> Value { return v }),
        ),
      ),
    ),
  )
}

// NOTE: the responsibility of freeing value and errors is in the hands of the user
parse :: proc(stream: []u8) -> (v: Value, ok: bool, errors: #soa[]Parser_Error) {
  ps := Parser_State{
    idx=0,
    errors=make_soa_dynamic_array(#soa[dynamic]Parser_Error)
  }
  // BUG: defer delete_soa_dynamic_array(ps.errors)

  resp_parser := value_p()
  defer resp_parser.destroy(resp_parser.ctx)
  pv, pok := resp_parser.run(resp_parser.ctx, stream, &ps)
  return pv, pok, ps.errors[:]
}
