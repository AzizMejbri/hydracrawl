package resp

import "core:testing"

@(test)
test_bulk_string_p :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := bulk_string_p()
  defer p.destroy(p.ctx)

  input := []u8{'$', '5', '\r', '\n', 'h', 'e', '\r', '\n', '!', '\r', '\n'}
  v, ok := p.run(p.ctx, input, &ps)
  defer delete(v.items)
  testing.expect(t, ok)
  testing.expect(t, ps.idx == uint(len(input)))
  testing.expect(t, v.len == 5)
  testing.expect(t, len(v.items) == 5)
  testing.expect(t, v.items[0] == 'h' && v.items[1] == 'e')
  testing.expect(t, v.items[2] == '\r' && v.items[3] == '\n' && v.items[4] == '!')

  ps.idx = 0
  _, ok3 := p.run(p.ctx, []u8{'$', '5', '\r', '\n', 'a', 'b'}, &ps)
  testing.expect(t, !ok3 && ps.idx == 0)

  ps.idx = 0
  nb, nok := p.run(p.ctx, []u8{'$', '-', '1', '\r', '\n'}, &ps)
  testing.expect(t, nok && nb.is_null && nb.items == nil && ps.idx == 5)

  ps.idx = 0
  eb, eok := p.run(p.ctx, []u8{'$', '0', '\r', '\n', '\r', '\n'}, &ps)
  defer delete(eb.items)
  testing.expect(t, eok && !eb.is_null && eb.len == 0 && len(eb.items) == 0 && ps.idx == 6)

  ps.idx = 0
  _, nok2 := p.run(p.ctx, []u8{'$', '-', '0', '\r', '\n'}, &ps)
  testing.expect(t, !nok2 && ps.idx == 0)

  ps.idx = 0
  _, nok3 := p.run(p.ctx, []u8{'$', '-', '2', '\r', '\n'}, &ps)
  testing.expect(t, !nok3 && ps.idx == 0)

  ps.idx = 0
  _, nok4 := p.run(p.ctx, []u8{'$', '-', '0', '1', '\r', '\n'}, &ps)
  testing.expect(t, !nok4 && ps.idx == 0)

  ps.idx = 0
  _, nok5 := p.run(p.ctx, []u8{'$', '+', '1', '\r', '\n'}, &ps)
  testing.expect(t, !nok5 && ps.idx == 0)

  ps.idx = 0
  _, nok6 := p.run(p.ctx, []u8{'$', '1', '8', '4', '4', '6', '7', '4', '4', '0', '7',
    '3', '7', '0', '9', '5', '5', '1', '6', '1', '5', '\r', '\n'}, &ps)
  testing.expect(t, !nok6 && ps.idx == 0)
}

@(test)
test_integer_p :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := integer_p()
  defer p.destroy(p.ctx)

  v, ok := p.run(p.ctx, []u8{':', '1', '2', '3', '\r', '\n'}, &ps)
  testing.expect(t, ok && v.raw == 123 && ps.idx == 6)

  ps.idx = 0
  z, zok := p.run(p.ctx, []u8{':', '0', '\r', '\n'}, &ps)
  testing.expect(t, zok && z.raw == 0 && ps.idx == 4)

  ps.idx = 0
  neg, negok := p.run(p.ctx, []u8{':', '-', '4', '2', '\r', '\n'}, &ps)
  testing.expect(t, negok && neg.raw == -42 && ps.idx == 6)

  ps.idx = 0
  maxv, maxok := p.run(p.ctx, []u8{':', '9', '2', '2', '3', '3', '7', '2', '0', '3',
    '6', '8', '5', '4', '7', '7', '5', '8', '0', '7', '\r', '\n'}, &ps)
  testing.expect(t, maxok && maxv.raw == max(i64))

  ps.idx = 0
  minv, minok := p.run(p.ctx, []u8{':', '-', '9', '2', '2', '3', '3', '7', '2', '0', '3',
    '6', '8', '5', '4', '7', '7', '5', '8', '0', '8', '\r', '\n'}, &ps)
  testing.expect(t, minok && minv.raw == min(i64))

  ps.idx = 0
  _, over := p.run(p.ctx, []u8{':', '9', '2', '2', '3', '3', '7', '2', '0', '3',
    '6', '8', '5', '4', '7', '7', '5', '8', '0', '8', '\r', '\n'}, &ps)
  testing.expect(t, !over && ps.idx == 0)

  ps.idx = 0
  _, under := p.run(p.ctx, []u8{':', '-', '9', '2', '2', '3', '3', '7', '2', '0', '3',
    '6', '8', '5', '4', '7', '7', '5', '8', '0', '9', '\r', '\n'}, &ps)
  testing.expect(t, !under && ps.idx == 0)

  ps.idx = 0
  _, plus := p.run(p.ctx, []u8{':', '+', '1', '\r', '\n'}, &ps)
  testing.expect(t, !plus && ps.idx == 0)

  ps.idx = 0
  _, nok := p.run(p.ctx, []u8{'1', '2', '3', '\r', '\n'}, &ps)
  testing.expect(t, !nok && ps.idx == 0)
}

@(test)
test_simple_string_p :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := simple_string_p()
  defer p.destroy(p.ctx)

  ss, ok := p.run(p.ctx, []u8{'+', 'O', 'K', '\r', '\n'}, &ps)
  defer delete(ss.items)
  testing.expect(t, ok)
  testing.expect(t, ss.len == 2 && len(ss.items) == 2 && ps.idx == 5)
  testing.expect(t, ss.items[0] == 'O' && ss.items[1] == 'K')

  ps.idx = 0
  empty, eok := p.run(p.ctx, []u8{'+', '\r', '\n'}, &ps)
  defer delete(empty.items)
  testing.expect(t, eok && empty.len == 0 && len(empty.items) == 0 && ps.idx == 3)

  ps.idx = 0
  text, tok := p.run(p.ctx, []u8{'+', 'H', 'e', 'l', 'l', 'o', ' ', 'W', 'o', 'r', 'l', 'd', '!', '\r', '\n'}, &ps)
  defer delete(text.items)
  testing.expect(t, tok && text.len == 12 && ps.idx == 15)
  testing.expect(t, string(text.items) == "Hello World!")

  ps.idx = 0
  utf8, uok := p.run(p.ctx, []u8{'+', 'h', 0xc3, 0xa9, 'l', 'l', 'o', '\r', '\n'}, &ps)
  defer delete(utf8.items)
  testing.expect(t, uok && utf8.len == 6 && ps.idx == 9)
  testing.expect(t, utf8.items[1] == 0xc3 && utf8.items[2] == 0xa9)

  ps.idx = 0
  _, cr := p.run(p.ctx, []u8{'+', 'a', '\r', 'b'}, &ps)
  testing.expect(t, !cr && ps.idx == 0)

  ps.idx = 0
  _, lf := p.run(p.ctx, []u8{'+', 'a', '\n', 'b', '\r', '\n'}, &ps)
  testing.expect(t, !lf && ps.idx == 0)

  ps.idx = 0
  _, incomplete := p.run(p.ctx, []u8{'+', 'a'}, &ps)
  testing.expect(t, !incomplete && ps.idx == 0)
}

@(test)
test_array_p :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := array_p()
  defer p.destroy(p.ctx)

  input := []u8{'*', '2', '\r', '\n', '$', '3', '\r', '\n', 'f', 'o', 'o', '\r', '\n', ':', '7', '\r', '\n'}
  a, ok := p.run(p.ctx, input, &ps)
  defer delete(a.items)
  testing.expect(t, ok && !a.is_null && a.len == 2 && ps.idx == uint(len(input)))

  if b, bok := a.items[0].(Bulk_String); bok {
    testing.expect(t, !b.is_null && len(b.items) == 3 && b.items[0] == 'f' && b.items[2] == 'o')
    delete(b.items)
  } else {
    testing.expect(t, false)
  }

  if n, nok := a.items[1].(Integer); nok {
    testing.expect(t, n.raw == 7)
  } else {
    testing.expect(t, false)
  }

  ps.idx = 0
  na, naok := p.run(p.ctx, []u8{'*', '-', '1', '\r', '\n'}, &ps)
  testing.expect(t, naok && na.is_null && na.items == nil && ps.idx == 5)

  ps.idx = 0
  ea, eaok := p.run(p.ctx, []u8{'*', '0', '\r', '\n'}, &ps)
  defer delete(ea.items)
  testing.expect(t, eaok && !ea.is_null && ea.len == 0 && len(ea.items) == 0 && ps.idx == 4)

  ps.idx = 0
  nested, nestedok := p.run(p.ctx, []u8{'*', '1', '\r', '\n', '*', '1', '\r', '\n', ':', '5', '\r', '\n'}, &ps)
  defer delete(nested.items)
  testing.expect(t, nestedok && nested.len == 1)
  if inner, iok := nested.items[0].(Array); iok {
    defer delete(inner.items)
    testing.expect(t, inner.len == 1)
    if n, nok := inner.items[0].(Integer); nok {
      testing.expect(t, n.raw == 5)
    } else {
      testing.expect(t, false)
    }
  } else {
    testing.expect(t, false)
  }
}

@(test)
test_error_p :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := error_p()
  defer p.destroy(p.ctx)

  input := []u8{'-', 'W', 'R', 'O', 'N', 'G', 'T', 'Y', 'P', 'E', ' ', 'b', 'a', 'd', ' ', 'v', 'a', 'l', 'u', 'e', '\r', '\n'}
  v, ok := p.run(p.ctx, input, &ps)
  defer delete(v.body)
  testing.expect(t, ok)
  testing.expect(t, ps.idx == uint(len(input)))
  testing.expect(t, v.kind_len == 9 && len(error_kind(v)) == 9)
  testing.expect(t, error_kind(v)[0] == 'W' && error_kind(v)[8] == 'E')
  testing.expect(t, len(error_msg(v)) == 9)
  testing.expect(t, error_msg(v)[0] == 'b' && error_msg(v)[3] == ' ')
  testing.expect(t, error_len(v) == 19)

  ps.idx = 0
  bare, bok := p.run(p.ctx, []u8{'-', 'E', 'R', 'R', '\r', '\n'}, &ps)
  defer delete(bare.body)
  testing.expect(t, bok && bare.kind_len == 3 && len(error_msg(bare)) == 0 && error_len(bare) == 3)
  testing.expect(t, ps.idx == 6)

  ps.idx = 0
  empty, eok := p.run(p.ctx, []u8{'-', '\r', '\n'}, &ps)
  defer delete(empty.body)
  testing.expect(t, eok && empty.kind_len == 0 && len(empty.body) == 0 && ps.idx == 3)

  ps.idx = 0
  leading, lok := p.run(p.ctx, []u8{'-', ' ', 'b', 'a', 'd', '\r', '\n'}, &ps)
  defer delete(leading.body)
  testing.expect(t, lok && leading.kind_len == 0 && string(error_msg(leading)) == "bad")

  ps.idx = 0
  trailing, tok := p.run(p.ctx, []u8{'-', 'E', 'R', 'R', ' ', '\r', '\n'}, &ps)
  defer delete(trailing.body)
  testing.expect(t, tok && trailing.kind_len == 3 && len(error_msg(trailing)) == 0)

  ps.idx = 0
  _, nok := p.run(p.ctx, []u8{'-', '\r', '\n'}, &ps)
  testing.expect(t, nok && ps.idx == 3)

  ps.idx = 0
  _, nok2 := p.run(p.ctx, []u8{'E', 'R', 'R', '\r', '\n'}, &ps)
  testing.expect(t, !nok2 && ps.idx == 0)

  ps.idx = 0
  _, nok3 := p.run(p.ctx, []u8{'-', 'a', '\r', 'b'}, &ps)
  testing.expect(t, !nok3 && ps.idx == 0)
}

@(test)
test_line_p_copies_body :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := line_p()
  defer p.destroy(p.ctx)

  input := []u8{'h', 'e', 'l', 'l', 'o', '\r', '\n'}
  body, ok := p.run(p.ctx, input, &ps)
  defer delete(body)
  testing.expect(t, ok && string(body) == "hello")

  input[0] = 'j'
  testing.expect(t, string(body) == "hello")
}

@(test)
test_take_p_overflow :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := take_p(max(uint), u8)
  defer p.destroy(p.ctx)

  _, ok := p.run(p.ctx, []u8{1, 2, 3}, &ps)
  testing.expect(t, !ok && ps.idx == 0)
}

@(test)
test_value_p :: proc(t: ^testing.T) {
  values := [][]u8{
    []u8{'+', 'O', 'K', '\r', '\n'},
    []u8{'-', 'E', 'R', 'R', ' ', 'n', 'o', '\r', '\n'},
    []u8{':', '4', '2', '\r', '\n'},
    []u8{'$', '3', '\r', '\n', 'f', 'o', 'o', '\r', '\n'},
    []u8{'*', '1', '\r', '\n', ':', '1', '\r', '\n'},
  }

  for input in values {
    ps: Parser_State
    p := value_p()
    v, ok := p.run(p.ctx, input, &ps)
    testing.expect(t, ok && ps.idx == uint(len(input)))

    switch x in v {
    case Simple_String:
      testing.expect(t, len(x.items) > 0)
    case Error:
      testing.expect(t, len(x.body) > 0)
    case Integer:
      testing.expect(t, x.raw == 42)
    case Bulk_String:
      testing.expect(t, !x.is_null && string(x.items) == "foo")
    case Array:
      testing.expect(t, !x.is_null && len(x.items) == 1)
    }

    deinit_value(&v)
    p.destroy(p.ctx)
    delete(ps.errors)
  }
}
