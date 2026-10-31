package resp

import "core:testing"

@(test)
test_just_and_just_if :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)
  input := []u8{'a', 'b', 'c'}
  p := just(u8('a'))
  defer p.destroy(p.ctx)
  v, ok := p.run(p.ctx, input, &ps)
  testing.expect(t, ok && v == 'a' && ps.idx == 1)

  pd := num_p()
  defer pd.destroy(pd.ctx)
  _, ok = pd.run(pd.ctx, input, &ps)
  testing.expect(t, !ok && ps.idx == 1 && len(ps.errors) == 1)
}

@(test)
test_sequencing_and_backtracking :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)
  input := []u8{'a', 'c'}

  seq := and_then(just(u8('a')), just(u8('b')))
  defer seq.destroy(seq.ctx)
  _, ok := seq.run(seq.ctx, input, &ps)
  testing.expect(t, !ok)
  testing.expect(t, ps.idx == 0)

  a := alt(
    and_then(just(u8('a')), just(u8('b'))),
    and_then(just(u8('a')), just(u8('c'))),
  )
  defer a.destroy(a.ctx)
  v, aok := a.run(a.ctx, input, &ps)
  testing.expect(t, aok)
  testing.expect(t, v.first == 'a' && v.second == 'c')
  testing.expect(t, ps.idx == 2)
}

@(test)
test_then_ignore_and_ignore_then :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)
  input := []u8{'a', 'b'}

  ti := then_ignore(just(u8('a')), just(u8('b')))
  defer ti.destroy(ti.ctx)
  v1, ok1 := ti.run(ti.ctx, input, &ps)
  testing.expect(t, ok1 && v1 == 'a' && ps.idx == 2)

  ps.idx = 0
  it := ignore_then(just(u8('a')), just(u8('b')))
  defer it.destroy(it.ctx)
  v2, ok2 := it.run(it.ctx, input, &ps)
  testing.expect(t, ok2 && v2 == 'b' && ps.idx == 2)
}

@(test)
test_or_not_and_many0 :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)
  input := []u8{'a', 'a', 'a', 'b'}

  on := or_not(just(u8('z')))
  defer on.destroy(on.ctx)
  v, ok := on.run(on.ctx, input, &ps)
  testing.expect(t, ok && v == nil && ps.idx == 0)
  testing.expect(t, len(ps.errors) == 0)

  m := many0(just(u8('a')))
  defer m.destroy(m.ctx)
  xs, mok := m.run(m.ctx, input, &ps)
  defer delete(xs)
  testing.expect(t, mok && len(xs) == 3 && ps.idx == 3)
  testing.expect(t, xs[0] == 'a' && xs[2] == 'a')

  m2 := many0(or_not(just(u8('z'))))
  defer m2.destroy(m2.ctx)
  _, _ = m2.run(m2.ctx, input[3:], &ps)
  testing.expect(t, len(ps.errors) == 1)
}

@(test)
test_many1 :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)
  input := []u8{'a', 'a', 'b'}

  m := many1(just(u8('a')))
  defer m.destroy(m.ctx)
  xs, ok := m.run(m.ctx, input, &ps)
  defer delete(xs)
  testing.expect(t, ok && len(xs) == 2 && ps.idx == 2)

  ps.idx = 2
  f := many1(just(u8('a')))
  defer f.destroy(f.ctx)
  _, fok := f.run(f.ctx, input, &ps)
  testing.expect(t, !fok && ps.idx == 2)
}

@(test)
test_separated_by :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)

  p := separated_by(alpha_p(), just(byte(',')))
  defer p.destroy(p.ctx)

  xs, ok := p.run(p.ctx, []u8{'a', ',', 'b', ',', 'c'}, &ps)
  defer delete(xs)
  testing.expect(t, ok && len(xs) == 3 && ps.idx == 5)
  testing.expect(t, xs[0] == 'a' && xs[2] == 'c')

  ps.idx = 0
  xs2, ok2 := p.run(p.ctx, []u8{'a', ',', 'b', ','}, &ps)
  defer delete(xs2)
  testing.expect(t, ok2 && len(xs2) == 2 && ps.idx == 3)

  ps.idx = 0
  xs3, ok3 := p.run(p.ctx, []u8{'#'}, &ps)
  defer delete(xs3)
  testing.expect(t, ok3 && len(xs3) == 0 && ps.idx == 0)

  ps.idx = 0
  lead := separated_by(alpha_p(), just(byte(',')), .ALLOW_LEADING)
  defer lead.destroy(lead.ctx)
  xs4, ok4 := lead.run(lead.ctx, []u8{',', 'a', ',', 'b'}, &ps)
  defer delete(xs4)
  testing.expect(t, ok4 && len(xs4) == 2 && ps.idx == 4)

  ps.idx = 0
  trail := separated_by(alpha_p(), just(byte(',')), .ALLOW_TRAILING)
  defer trail.destroy(trail.ctx)
  xs5, ok5 := trail.run(trail.ctx, []u8{'a', ',', 'b', ','}, &ps)
  defer delete(xs5)
  testing.expect(t, ok5 && len(xs5) == 2 && ps.idx == 4)
}

@(test)
test_parser_map :: proc(t: ^testing.T) {
  ps: Parser_State
  defer delete(ps.errors)
  p := parser_map(just(u8('a')), proc(c: u8) -> int { return int(c) })
  defer p.destroy(p.ctx)
  v, ok := p.run(p.ctx, []u8{'a'}, &ps)
  testing.expect(t, ok && v == int('a'))
}
