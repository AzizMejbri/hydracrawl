package main

import "core:fmt"
import "green"
import "server"
import "store"

port :: server.DEFAULT_PORT

main :: proc() {
  // initialize storage, pass it throuh every fiber with context
  data: store.Store
  store.store_init(&data)
  defer store.store_deinit(&data)
  context.user_ptr = &data

  // initialize and run the async runtime
	green.rt_init()
	defer green.rt_deinit()
	green.spawn(server.listener, port)
	green.run()
	fmt.println("Finished running")
}
