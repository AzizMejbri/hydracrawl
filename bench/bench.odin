package main

import "core:fmt"
import "core:time"

report :: proc(name: string, iters: int, d: time.Duration) {
	ns := time.duration_nanoseconds(d)
	per_op := f64(ns) / f64(iters)
	fmt.printfln("%-32s %10d iters  %10.2f ns/op  %12d ns total", name, iters, per_op, ns)
}

main :: proc() {
	fmt.println("hydracrawl component benchmarks\n")
	bench_resp_parse()
	bench_resp_write()
	bench_store_set()
	bench_store_get()
	bench_store_incr()
	bench_dispatch_set()
	bench_dispatch_get()
	bench_pipeline_set()
	bench_pipeline_get()
}
