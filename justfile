set shell := ["bash", "-euo", "pipefail", "-c"]

project := "hydracrawl"
src := "src"
out := "build"
bin := out + "/" + project

# Build the project (same as `just build`)
default: build

# Show all recipes, or usage for one (e.g. `just help run`)
[group('help')]
help RECIPE="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -z "{{RECIPE}}" ]]; then
        just --justfile "{{justfile()}}" --list
    elif ! just --justfile "{{justfile()}}" --show "{{RECIPE}}" 2>/dev/null; then
        echo "unknown recipe: {{RECIPE}}" >&2
        exit 1
    fi

# Assemble hand-written .s files next to their sources so each package's
# foreign import resolves the same way standalone or as a submodule
[group('build')]
asm:
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r s; do
        as "$s" -o "${s%.s}.o"
    done < <(find {{src}} -name '*.s')

# Build a debug-friendly binary
[group('build')]
build: asm
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}} -vet

# Build an optimized release binary
[group('build')]
release: asm
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}} -o:speed -microarch:native -no-bounds-check -disable-assert

# Build with debug info and no optimizations
[group('build')]
debug: asm
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}}-debug -debug

# Type-check and vet every package
[group('build')]
check: asm
    #!/usr/bin/env bash
    set -euo pipefail
    while IFS= read -r dir; do
        echo "==> check $dir"
        odin check "$dir" -vet -no-entry-point
    done < <(find {{src}} bench -name '*.odin' -printf '%h\n' | sort -u)

# Remove the build directory
[group('build')]
clean:
    rm -rf {{out}}

# Run from source; pass program args after `--`
[group('run')]
run *ARGS:
    odin run {{src}} -- {{ARGS}}

# Run the optimized release binary
[group('run')]
run-release *ARGS: release
    ./{{bin}} {{ARGS}}

# Run the debug binary
[group('run')]
run-debug *ARGS: debug
    ./{{bin}}-debug {{ARGS}}

# Run tests in every package; one package failing doesn't stop the rest
[group('test')]
test: asm
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    while IFS= read -r dir; do
        echo "==> test $dir"
        odin test "$dir" -vet || failed=1
    done < <(find {{src}} -name '*.odin' -printf '%h\n' | sort -u)
    exit $failed

# Run tests with AddressSanitizer; one package failing doesn't stop the rest
[group('test')]
test-asan: asm
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    while IFS= read -r dir; do
        echo "==> test $dir (address)"
        odin test "$dir" -vet -sanitize:address || failed=1
    done < <(find {{src}} -name '*.odin' -printf '%h\n' | sort -u)
    exit $failed

# Run tests with ThreadSanitizer; one package failing doesn't stop the rest
[group('test')]
test-tsan: asm
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    while IFS= read -r dir; do
        echo "==> test $dir (thread)"
        odin test "$dir" -vet -sanitize:thread || failed=1
    done < <(find {{src}} -name '*.odin' -printf '%h\n' | sort -u)
    exit $failed

# Launch the debug binary under gdb
[group('debug')]
debug-gdb *ARGS: debug
    gdb -q -ex run -ex bt --args ./{{bin}}-debug {{ARGS}}

# Launch the debug binary under lldb
[group('debug')]
debug-lldb *ARGS: debug
    lldb -- ./{{bin}}-debug {{ARGS}}

# Build and run the benchmark executable
[group('bench')]
bench *ARGS:
    @mkdir -p {{out}}
    odin build bench -out:{{out}}/bench -o:speed -microarch:native
    ./{{out}}/bench {{ARGS}}

# Benchmark the release binary with hyperfine
[group('bench')]
bench-hyperfine *ARGS: release
    hyperfine --warmup 3 './{{bin}} {{ARGS}}'

# Profile with perf record and open the report
[group('profile')]
profile *ARGS:
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}}-profile -o:speed -debug -microarch:native
    perf record -g --call-graph dwarf -o {{out}}/perf.data ./{{bin}}-profile {{ARGS}}
    perf report -i {{out}}/perf.data

# Show perf stat counters
[group('profile')]
profile-stat *ARGS:
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}}-profile -o:speed -debug -microarch:native
    perf stat ./{{bin}}-profile {{ARGS}}

# Profile with valgrind callgrind
[group('profile')]
callgrind *ARGS:
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}}-debug -debug
    valgrind --tool=callgrind --callgrind-out-file={{out}}/callgrind.out ./{{bin}}-debug {{ARGS}}
    callgrind_annotate {{out}}/callgrind.out

# Track heap allocations with heaptrack
[group('profile')]
heaptrack *ARGS:
    @mkdir -p {{out}}
    odin build {{src}} -out:{{bin}}-debug -debug
    heaptrack ./{{bin}}-debug {{ARGS}}
