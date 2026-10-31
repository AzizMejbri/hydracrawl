package resp

import "core:testing"

@(private)
expect_written :: proc(t: ^testing.T, v: Value, want: string) {
  buf: [dynamic]u8
  defer delete(buf)
  resp_write(&buf, v)
  testing.expectf(t, string(buf[:]) == want, "got %q, want %q", string(buf[:]), want)
}

@(test)
test_resp_write_scalars :: proc(t: ^testing.T) {
  expect_written(t, Simple_String{ items = []u8{'O', 'K'} }, "+OK\r\n")
  expect_written(t, Simple_String{}, "+\r\n")
  expect_written(
    t,
    Error{ body = []u8{'E', 'R', 'R', ' ', 'b', 'a', 'd'}, kind_len = 3 },
    "-ERR bad\r\n",
  )
  expect_written(t, Integer{ raw = 0 }, ":0\r\n")
  expect_written(t, Integer{ raw = 42 }, ":42\r\n")
  expect_written(t, Integer{ raw = -42 }, ":-42\r\n")
  expect_written(t, Integer{ raw = max(i64) }, ":9223372036854775807\r\n")
  expect_written(t, Integer{ raw = min(i64) }, ":-9223372036854775808\r\n")
}

@(test)
test_resp_write_bulk_strings :: proc(t: ^testing.T) {
  expect_written(t, null_bulk(), "$-1\r\n")
  expect_written(t, Bulk_String{}, "$0\r\n\r\n")
  expect_written(t, Bulk_String{ items = []u8{'f', 'o', 'o'} }, "$3\r\nfoo\r\n")
  expect_written(
    t,
    Bulk_String{ items = []u8{'a', '\r', '\n', 'b'} },
    "$4\r\na\r\nb\r\n",
  )
}

@(test)
test_resp_write_arrays :: proc(t: ^testing.T) {
  expect_written(t, Array{ is_null = true }, "*-1\r\n")
  expect_written(t, Array{}, "*0\r\n")
  expect_written(
    t,
    Array{ items = []Value{
      Simple_String{ items = []u8{'O', 'K'} },
      Integer{ raw = 7 },
      Bulk_String{ is_null = true },
    } },
    "*3\r\n+OK\r\n:7\r\n$-1\r\n",
  )
  expect_written(
    t,
    Array{ items = []Value{
      Array{ items = []Value{ Integer{ raw = 5 } } },
    } },
    "*1\r\n*1\r\n:5\r\n",
  )
}

@(test)
test_resp_write_round_trip :: proc(t: ^testing.T) {
  inputs := [][]u8{
    []u8{'+', 'O', 'K', '\r', '\n'},
    []u8{'+', '\r', '\n'},
    []u8{'-', 'E', 'R', 'R', ' ', 'b', 'a', 'd', '\r', '\n'},
    []u8{':', '-', '4', '2', '\r', '\n'},
    []u8{':', '9', '2', '2', '3', '3', '7', '2', '0', '3', '6', '8', '5', '4', '7',
      '7', '5', '8', '0', '7', '\r', '\n'},
    []u8{'$', '-', '1', '\r', '\n'},
    []u8{'$', '0', '\r', '\n', '\r', '\n'},
    []u8{'$', '3', '\r', '\n', 'f', 'o', 'o', '\r', '\n'},
    []u8{'*', '-', '1', '\r', '\n'},
    []u8{'*', '0', '\r', '\n'},
    []u8{'*', '2', '\r', '\n', ':', '1', '\r', '\n', '$', '3', '\r', '\n', 'f', 'o', 'o', '\r', '\n'},
    []u8{'*', '1', '\r', '\n', '*', '1', '\r', '\n', ':', '5', '\r', '\n'},
  }

  ps: Parser_State
  defer delete(ps.errors)
  p := value_p()
  defer p.destroy(p.ctx)

  for input in inputs {
    ps.idx = 0
    v, ok := p.run(p.ctx, input, &ps)
    testing.expect(t, ok)
    if !ok {
      continue
    }

    buf: [dynamic]u8
    resp_write(&buf, v)
    testing.expectf(
      t,
      string(buf[:]) == string(input),
      "round trip got %q, want %q",
      string(buf[:]),
      string(input),
    )

    delete(buf)
    deinit_value(&v)
  }
}
