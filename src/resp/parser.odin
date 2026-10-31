package resp

Pair :: struct($A, $B: typeid) {
  first: A,
  second: B,
}

Parser_Error :: struct {
  idx: uint,
  msg: string,
}

Parser_State :: struct {
  idx: uint,
  errors: #soa[dynamic]Parser_Error,
}

Parser :: struct($I, $O: typeid) {
  run: proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: O, ok: bool),
  ctx: rawptr,
  destroy: proc(ctx: rawptr),
}

Just_State :: struct($T: typeid) {
  val: T,
}

Just_If_State :: struct($T: typeid) {
  pred: proc(T) -> bool,
}

Take_State :: struct($T: typeid) {
  n: uint,
}

Map_State :: struct($I, $A, $B: typeid) {
  p: Parser(I, A),
  f: proc(A) -> B,
}

Bind_State :: struct($I, $A, $B: typeid) {
  p: Parser(I, A),
  f: proc(A) -> Parser(I, B),
}

Or_Not_State :: struct($I, $O: typeid) {
  p: Parser(I, O),
}

And_Then_State :: struct($I, $A, $B: typeid) {
  p1: Parser(I, A),
  p2: Parser(I, B),
}

Then_Ignore_State :: struct($I, $A, $B: typeid) {
  p1: Parser(I, A),
  p2: Parser(I, B),
}

Alt_State :: struct($I, $O: typeid) {
  p1: Parser(I, O),
  p2: Parser(I, O),
}

Many0_State :: struct($I, $O: typeid) {
  p: Parser(I, O),
}

Count_State :: struct($I, $O: typeid) {
  p: Parser(I, O),
  n: uint,
}

Succeed_State :: struct($T: typeid) {
  val: T,
}

Separated_By_State :: struct($I, $O, $S: typeid) {
  p: Parser(I, O),
  sep: Parser(I, S),
  flag: Separated_By_Flag,
}

just :: proc(val: $T) -> Parser(T, T) {
  result: Parser(T, T)
  state := new(Just_State(T))
  state.val = val
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    free(cast(^Just_State(T))ctx)
  }
  result.run = proc(ctx: rawptr, input: []T, ps: ^Parser_State) -> (output: T, ok: bool) {
    s := cast(^Just_State(T))ctx
    if ps.idx >= uint(len(input)) {
      error("unexpected end of input", ps)
      return {}, false
    }
    if input[ps.idx] == s.val {
      ps.idx += 1
      return s.val, true
    }
    error("unexpected token", ps)
    return {}, false
  }
  return result
}

just_if :: proc(pred: proc($T) -> bool) -> Parser(T, T) {
  result: Parser(T, T)
  state := new(Just_If_State(T))
  state.pred = pred
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    free(cast(^Just_If_State(T))ctx)
  }
  result.run = proc(ctx: rawptr, input: []T, ps: ^Parser_State) -> (output: T, ok: bool) {
    s := cast(^Just_If_State(T))ctx
    if ps.idx >= uint(len(input)) {
      error("unexpected end of input", ps)
      return {}, false
    }
    c := input[ps.idx]
    if s.pred(c) {
      ps.idx += 1
      return c, true
    }
    error("predicate failed", ps)
    return {}, false
  }
  return result
}

take_p :: proc(n: uint, $T: typeid) -> Parser(T, []T) {
  result: Parser(T, []T)
  state := new(Take_State(T))
  state.n = n
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    free(cast(^Take_State(T))ctx)
  }
  result.run = proc(ctx: rawptr, input: []T, ps: ^Parser_State) -> (output: []T, ok: bool) {
    s := cast(^Take_State(T))ctx
    start := ps.idx
    input_len := uint(len(input))
    if start > input_len || s.n > input_len - start {
      error("take_p: not enough input", ps)
      return nil, false
    }
    ps.idx = start + s.n
    items := make([]T, s.n)
    copy(items, input[start:ps.idx])
    return items, true
  }
  return result
}

succeed_p :: proc(val: $T, $I: typeid) -> Parser(I, T) {
  result: Parser(I, T)
  state := new(Succeed_State(T))
  state.val = val
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    free(cast(^Succeed_State(T))ctx)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: T, ok: bool) {
    s := cast(^Succeed_State(T))ctx
    return s.val, true
  }
  return result
}

parser_map :: proc(p: Parser($I, $A), f: proc(A) -> $B) -> Parser(I, B) {
  result: Parser(I, B)
  state := new(Map_State(I, A, B))
  state.p = p
  state.f = f
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Map_State(I, A, B))ctx
    s.p.destroy(s.p.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: B, ok: bool) {
    s := cast(^Map_State(I, A, B))ctx
    out, pok := s.p.run(s.p.ctx, input, ps)
    if !pok {
      return {}, false
    }
    return s.f(out), true
  }
  return result
}

bind :: proc(p: Parser($I, $A), f: proc(A) -> Parser(I, $B)) -> Parser(I, B) {
  result: Parser(I, B)
  state := new(Bind_State(I, A, B))
  state.p = p
  state.f = f
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Bind_State(I, A, B))ctx
    s.p.destroy(s.p.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: B, ok: bool) {
    s := cast(^Bind_State(I, A, B))ctx
    start := ps.idx
    a, pok := s.p.run(s.p.ctx, input, ps)
    if !pok {
      ps.idx = start
      return {}, false
    }
    next := s.f(a)
    out, nok := next.run(next.ctx, input, ps)
    next.destroy(next.ctx)
    if !nok {
      ps.idx = start
      return {}, false
    }
    return out, true
  }
  return result
}

or_not :: proc(p: Parser($I, $O)) -> Parser(I, Maybe(O)) {
  result: Parser(I, Maybe(O))
  state := new(Or_Not_State(I, O))
  state.p = p
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Or_Not_State(I, O))ctx
    s.p.destroy(s.p.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: Maybe(O), ok: bool) {
    s := cast(^Or_Not_State(I, O))ctx
    save := ps.idx
    save_errors := len(ps.errors)
    out, pok := s.p.run(s.p.ctx, input, ps)
    if !pok {
      ps.idx = save
      errors_truncate(ps, save_errors)
      return nil, true
    }
    return out, true
  }
  return result
}

and_then :: proc(p1: Parser($I, $A), p2: Parser(I, $B)) -> Parser(I, Pair(A, B)) {
  result: Parser(I, Pair(A, B))
  state := new(And_Then_State(I, A, B))
  state.p1 = p1
  state.p2 = p2
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^And_Then_State(I, A, B))ctx
    s.p1.destroy(s.p1.ctx)
    s.p2.destroy(s.p2.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: Pair(A, B), ok: bool) {
    s := cast(^And_Then_State(I, A, B))ctx
    save := ps.idx
    a, aok := s.p1.run(s.p1.ctx, input, ps)
    if !aok {
      ps.idx = save
      return {}, false
    }
    b, bok := s.p2.run(s.p2.ctx, input, ps)
    if !bok {
      ps.idx = save
      return {}, false
    }
    return Pair(A, B){ first=a, second=b }, true
  }
  return result
}

then_ignore :: proc(p1: Parser($I, $A), p2: Parser(I, $B)) -> Parser(I, A) {
  result: Parser(I, A)
  state := new(Then_Ignore_State(I, A, B))
  state.p1 = p1
  state.p2 = p2
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Then_Ignore_State(I, A, B))ctx
    s.p1.destroy(s.p1.ctx)
    s.p2.destroy(s.p2.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: A, ok: bool) {
    s := cast(^Then_Ignore_State(I, A, B))ctx
    save := ps.idx
    a, aok := s.p1.run(s.p1.ctx, input, ps)
    if !aok {
      ps.idx = save
      return {}, false
    }
    _, bok := s.p2.run(s.p2.ctx, input, ps)
    if !bok {
      ps.idx = save
      return {}, false
    }
    return a, true
  }
  return result
}

ignore_then :: proc(p1: Parser($I, $A), p2: Parser(I, $B)) -> Parser(I, B) {
  result: Parser(I, B)
  state := new(Then_Ignore_State(I, A, B))
  state.p1 = p1
  state.p2 = p2
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Then_Ignore_State(I, A, B))ctx
    s.p1.destroy(s.p1.ctx)
    s.p2.destroy(s.p2.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: B, ok: bool) {
    s := cast(^Then_Ignore_State(I, A, B))ctx
    save := ps.idx
    _, aok := s.p1.run(s.p1.ctx, input, ps)
    if !aok {
      ps.idx = save
      return {}, false
    }
    b, bok := s.p2.run(s.p2.ctx, input, ps)
    if !bok {
      ps.idx = save
      return {}, false
    }
    return b, true
  }
  return result
}

alt :: proc(p1: Parser($I, $O), p2: Parser(I, O)) -> Parser(I, O) {
  result: Parser(I, O)
  state := new(Alt_State(I, O))
  state.p1 = p1
  state.p2 = p2
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Alt_State(I, O))ctx
    s.p1.destroy(s.p1.ctx)
    s.p2.destroy(s.p2.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: O, ok: bool) {
    s := cast(^Alt_State(I, O))ctx
    save := ps.idx
    save_errors := len(ps.errors)
    a, aok := s.p1.run(s.p1.ctx, input, ps)
    if aok {
      return a, true
    }
    ps.idx = save
    errors_truncate(ps, save_errors)
    b, bok := s.p2.run(s.p2.ctx, input, ps)
    if bok {
      return b, true
    }
    ps.idx = save
    return {}, false
  }
  return result
}

many0 :: proc(p: Parser($I, $O)) -> Parser(I, []O) {
  result: Parser(I, []O)
  state := new(Many0_State(I, O))
  state.p = p
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Many0_State(I, O))ctx
    s.p.destroy(s.p.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: []O, ok: bool) {
    s := cast(^Many0_State(I, O))ctx
    items := make([dynamic]O)
    for {
      save := ps.idx
      save_errors := len(ps.errors)
      o, pok := s.p.run(s.p.ctx, input, ps)
      if !pok {
        ps.idx = save
        errors_truncate(ps, save_errors)
        break
      }
      if ps.idx == save {
        error("many0: parser succeeded without consuming input", ps)
        break
      }
      append(&items, o)
    }
    return items[:], true
  }
  return result
}

many1 :: proc(p: Parser($I, $O)) -> Parser(I, []O) {
  result: Parser(I, []O)
  state := new(Many0_State(I, O))
  state.p = p
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Many0_State(I, O))ctx
    s.p.destroy(s.p.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: []O, ok: bool) {
    s := cast(^Many0_State(I, O))ctx
    start := ps.idx
    first, pok := s.p.run(s.p.ctx, input, ps)
    if !pok {
      ps.idx = start
      return nil, false
    }
    if ps.idx == start {
      error("many1: parser succeeded without consuming input", ps)
      return nil, false
    }
    items := make([dynamic]O)
    append(&items, first)
    for {
      save := ps.idx
      save_errors := len(ps.errors)
      o, mok := s.p.run(s.p.ctx, input, ps)
      if !mok {
        ps.idx = save
        errors_truncate(ps, save_errors)
        break
      }
      if ps.idx == save {
        error("many1: parser succeeded without consuming input", ps)
        break
      }
      append(&items, o)
    }
    return items[:], true
  }
  return result
}

Separated_By_Flag :: enum {
  ALLOW_NONE,
  ALLOW_LEADING,
  ALLOW_TRAILING,
}

count_p :: proc(p: Parser($I, $O), n: uint) -> Parser(I, []O) {
  result: Parser(I, []O)
  state := new(Count_State(I, O))
  state.p = p
  state.n = n
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Count_State(I, O))ctx
    s.p.destroy(s.p.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: []O, ok: bool) {
    s := cast(^Count_State(I, O))ctx
    items := make([dynamic]O)
    start := ps.idx
    start_errors := len(ps.errors)
    for _ in 0..<s.n {
      o, pok := s.p.run(s.p.ctx, input, ps)
      if !pok {
        ps.idx = start
        errors_truncate(ps, start_errors)
        delete(items)
        return nil, false
      }
      append(&items, o)
    }
    return items[:], true
  }
  return result
}

separated_by :: proc(p: Parser($I, $O), sep: Parser(I, $S), flag: Separated_By_Flag = .ALLOW_NONE) -> Parser(I, []O) {
  result: Parser(I, []O)
  state := new(Separated_By_State(I, O, S))
  state.p = p
  state.sep = sep
  state.flag = flag
  result.ctx = cast(rawptr)state
  result.destroy = proc(ctx: rawptr) {
    s := cast(^Separated_By_State(I, O, S))ctx
    s.p.destroy(s.p.ctx)
    s.sep.destroy(s.sep.ctx)
    free(s)
  }
  result.run = proc(ctx: rawptr, input: []I, ps: ^Parser_State) -> (output: []O, ok: bool) {
    s := cast(^Separated_By_State(I, O, S))ctx
    items := make([dynamic]O)
    start := ps.idx
    start_errors := len(ps.errors)

    if s.flag == .ALLOW_LEADING {
      _, sok := s.sep.run(s.sep.ctx, input, ps)
      if !sok {
        ps.idx = start
        errors_truncate(ps, start_errors)
      }
    }

    first_start := ps.idx
    first, pok := s.p.run(s.p.ctx, input, ps)
    if !pok {
      ps.idx = start
      errors_truncate(ps, start_errors)
      return items[:], true
    }
    if ps.idx == first_start {
      error("separated_by: parser succeeded without consuming input", ps)
      return items[:], true
    }
    append(&items, first)

    for {
      sep_start := ps.idx
      sep_errors := len(ps.errors)
      _, sok := s.sep.run(s.sep.ctx, input, ps)
      if !sok {
        ps.idx = sep_start
        errors_truncate(ps, sep_errors)
        break
      }
      if ps.idx == sep_start {
        error("separated_by: separator succeeded without consuming input", ps)
        break
      }
      item_start := ps.idx
      item_errors := len(ps.errors)
      o, iok := s.p.run(s.p.ctx, input, ps)
      if !iok {
        if s.flag == .ALLOW_TRAILING {
          errors_truncate(ps, item_errors)
        } else {
          ps.idx = sep_start
          errors_truncate(ps, sep_errors)
        }
        break
      }
      if ps.idx == item_start {
        error("separated_by: parser succeeded without consuming input", ps)
        break
      }
      append(&items, o)
    }
    return items[:], true
  }
  return result
}

error :: proc(msg: string, ps: ^Parser_State) {
  append(&ps.errors, Parser_Error{ idx = ps.idx, msg = msg })
}

errors_truncate :: proc(ps: ^Parser_State, n: int) {
  resize(&ps.errors, n)
}

alpha_p :: proc() -> Parser(u8, u8) {
  return just_if(proc(c: u8) -> bool { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') })
}

num_p :: proc() -> Parser(u8, u8) {
  return just_if(proc(c: u8) -> bool { return c >= '0' && c <= '9' })
}


