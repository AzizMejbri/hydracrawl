package server

import "core:sys/linux"
import "core:net"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import green "../green"
import resp "../resp"
import store "../store"

DEFAULT_PORT :: 6378
MAX_RECV_BUFFER_LEN :: 1024
MAX_SEND_BUFFER_LEN :: 1024
LOCAL_HOST :: net.IP4_Address{127,0,0,1}

Conn_Fiber_Args :: struct {
  client_sock: linux.Fd,
  client_addr: net.Endpoint,
}

listener :: proc(port: int = DEFAULT_PORT) {
  // listen for incoming connections
  listen_sock, listen_err := net.listen_tcp(net.Endpoint{
    port=port,
    address=LOCAL_HOST,
  })
  if listen_err != nil {
    fmt.println("Failed to listen:", listen_err)
    green.exit() 
  }
  defer net.close(listen_sock)

  // preparin the request for asynchronous accept() of incoming connections
  client_addr: linux.Sock_Addr_Any
  client_addr_len: i32 = size_of(linux.Sock_Addr_In)
  req: green.Request_Params = green.Accept_Params {
    fd=linux.Fd(listen_sock),
    addr=&client_addr,
    addr_len=&client_addr_len,
  }

  for {
    // accept() asynchronously
    accepted_fd := green.request(&req)

    // accept() failure, just log move on
    if accepted_fd < 0 {
      fmt.eprintln("Failed to accept the connection on the listen_sock=", listen_sock,
        ", err=", linux.Errno(accepted_fd))
      continue
    }

    // allocate a logger for the fiber, ownership is passed ot it 
    context.logger = log.create_console_logger()

    // spawn the fiber, pass the client data and implicitly odin's runtime context
    green.spawn(conn_loop, Conn_Fiber_Args{
      client_sock=linux.Fd(accepted_fd),
      client_addr=net.Endpoint{
        address=net.IP4_Address(client_addr.sin_addr),
        port=int(client_addr.sin_port)
      },
    }, 256 * 1024)
  }
}

conn_loop :: proc(args: Conn_Fiber_Args) {
  defer net.close(net.TCP_Socket(args.client_sock))
  defer log.destroy_console_logger(context.logger)

  recv_buf: [MAX_RECV_BUFFER_LEN]u8
  send_buf: [dynamic]u8
  // pin send_buf's own backing storage to the heap allocator *before*
  // context.allocator gets switched to the per-fiber arena below --
  // otherwise its first growth (inside resp.resp_write) would pull from
  // the arena too, and the arena reset each round would free the wire
  // buffer out from under the in-flight send
  reserve(&send_buf, MAX_SEND_BUFFER_LEN)
  defer delete(send_buf)

  // every resp.Value this fiber builds (parse results, dispatch replies,
  // error values) comes from this arena instead of the heap -- reset in
  // bulk at the top of each round instead of individually deinit'd, which
  // also sidesteps the double-free class of bug that bit resp.parse
  // earlier
  value_arena: virtual.Arena
  arena_err := virtual.arena_init_growing(&value_arena)
  ensure(arena_err == nil, "conn_loop: failed to init the per-fiber value arena")
  defer virtual.arena_destroy(&value_arena)
  context.allocator = virtual.arena_allocator(&value_arena)

  // prepare async syscalls parameters using allocated buffers
  // stack-allocated static buffer, will change later for security
  recv_params: green.Request_Params = green.Recv_Params{
    fd=args.client_sock,
    buf=recv_buf[:]
  }
  fiber_id := green.get_id()

  // first action: log the connection that we recieved from our current fiber
  log.log(log.Level.Info,  "Fiber <<", fiber_id ,">> Recieved a connection from address=",
    args.client_addr.address, " port=", args.client_addr.port, "\n")

  response_len := green.request(&recv_params)
  for; response_len > 0; response_len = green.request(&recv_params){
    if recv_buf[0] == 0x04 {
      _cold_marker()
      break
    }

    // log that we got a message
    log.log(log.Level.Info, "Fiber <<", fiber_id, ">> Recieved a message from address=",
            args.client_addr.address, " port=", args.client_addr.port,": ", string(recv_buf[:response_len]))

    // reset per-round state: send_buf's length (it's declared once
    // outside this loop, so without this every reply would get appended
    // after the last one) and every resp.Value this fiber has allocated
    // since the last round -- one bulk reset instead of individually
    // deinit'ing v/reply/err_reply/errors below
    clear(&send_buf)
    virtual.arena_free_all(&value_arena)

    // parse the message
    v, ok, errors := resp.parse(recv_buf[:])

    // prepare a response to send for both cases, success and failure:
    // parse success:
    if ok {
      log.log(log.Level.Info, "Fiber <<", fiber_id, ">> Parse succesful, value: ", v)

      // every command handler that writes to the store (there are 9
      // separate store.put call sites across commands.odin, and more
      // will likely be added) builds its new value under whatever
      // context.allocator is ambient, then hands it to store.put, which
      // -- by design, to support cheap moves elsewhere in store.odin --
      // trusts the caller already allocated it correctly. Swapping here,
      // around the single chokepoint every command flows through, is
      // what makes that true without having to touch every handler:
      // anything persisted ends up allocated with the store's own
      // allocator instead of this connection's arena. The reply itself
      // rides along on the same swap, so it must be explicitly freed
      // below -- arena_free_all won't reach it.
      db := cast(^store.Store)(context.user_ptr)
      prev_allocator := context.allocator
      context.allocator = db.allocator
      reply := dispatch_value(db, v)
      resp.resp_write(&send_buf, reply)
      resp.deinit_value(&reply)
      context.allocator = prev_allocator
    } // parse failure:
    else {
      log.log(log.Level.Info, "Fiber <<", green.get_id(), ">> Parse Failed with errors: [")
      for err in errors {
        log.log(log.Level.Info, "\t", err, ",")
        err_reply: resp.Value = resp.error_from_string(err.msg)
        resp.resp_write(&send_buf, err_reply)
      }
      log.log(log.Level.Info, "]")
    }

    // build Send_Params fresh, now that send_buf actually holds this
    // round's reply -- slicing send_buf earlier (e.g. before the loop)
    // would freeze buf at whatever send_buf looked like back then, not
    // what's actually in it now
    if len(send_buf) > 0 {
      send_params: green.Request_Params = green.Send_Params{
        fd=args.client_sock,
        buf=send_buf[:],
      }
      green.request(&send_params)
    }
  }

  log.log(log.Level.Info, "Fiber <<", fiber_id, ">> The connection from address=",
    args.client_addr.address, " port=", args.client_addr.port, " has been terminated")
  
}


@(private="file", cold)
_cold_marker :: proc() {}
