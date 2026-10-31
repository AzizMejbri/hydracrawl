package command

import resp "../../resp"
import store "../../store"

@(private)
clone_bulk :: proc(arg: resp.Bulk_String) -> resp.Value {
  value: resp.Value = arg
  return resp.init_value(value)
}

handle_ping :: proc(_: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  switch len(args) {
  case 0:
    return resp.simple_string_from_string("PONG")
  case 1:
    return clone_bulk(args[0])
  case:
    return wrong_arity("ping")
  }
}

handle_echo :: proc(_: ^store.Store, args: []resp.Bulk_String) -> resp.Value {
  if len(args) != 1 {
    return wrong_arity("echo")
  }
  return clone_bulk(args[0])
}
