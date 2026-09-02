# go-aros

**Porting the Go gc toolchain to AROS x86_64. Early: the toolchain knows the
platform, the runtime does not exist yet, and no Go program runs on AROS.**

That status line is the honest summary; the rest of this file is what has been
established, and what has not.

## Where it stands

| | |
|---|---|
| Thread pointer on AROS | **done** — see [aros-tls](https://github.com/tomaszstaniak/aros-tls) |
| `GOOS=aros` accepted by the toolchain | **done** |
| `MOVQ TLS, r` lowering | **done, verified by disassembly** |
| `package runtime` compiles | no — 37 undefined OS-layer symbols |
| `syscall`, `os` | not started |
| Anything running on AROS | **no** |

## Why bother, and why the gc toolchain

**gccgo is a dead end.** `libgo/VERSION` reads `go1.18` in GCC 13, 14, 15 *and*
master — frozen since 2023 — while GCC 10.5, which the AROS toolchain ships,
gives `go1.14.6`. Real targets need far newer: Syncthing's `go.mod` asks for
`go 1.26.2`. Eight language versions of drift, generics among them. So gc it is.

Two things make the gc toolchain's surface smaller than it looks:

**TLS is one lowering point, not a scattered dependency.** `get_tls(r)` on
amd64 is the pseudo-instruction `MOVQ TLS, r` (`runtime/go_tls.h`), lowered in
exactly one place, `cmd/internal/obj/x86/asm6.go`. Plan 9's case there is a
single `MOV` from a global symbol, and `runtime·settls` on Plan 9 is a bare
`RET`. `g` itself lives in **R14** under ABIInternal (`REGG = REG_R14`); TLS is
only how `g` is *recovered* at boundaries — thread entry, signal delivery,
entry from C.

**External linking should sidestep the executable format.** AROS executables
are `ET_REL`, which Go's linker does not emit. `-linkmode=external` hands the
final link to a host linker, so `x86_64-aros-gcc` and the SDK's linker script
would do that part and Go's linker never learns the format. *This is reasoning,
not a measurement* — it cannot be tested until a runtime compiles, and if it
turns out to be wrong it changes the shape of the rest.

The compiler is written in Go and cross-compiles, so the toolchain builds on
the development host. Nothing has to run on AROS for the toolchain to exist.

## Patch 1: the thread pointer lowering

Seven registration points, no runtime involved:

| file | change |
|---|---|
| `internal/syslist` | `aros` in `KnownOS` |
| `cmd/internal/objabi/head.go` | `Haros`, `Set()`, `String()` |
| `cmd/internal/obj/x86/obj6.go` | `ArosTLSOffset = 24`; `CanUse1InsnTLS` false; Plan 9's scale marker |
| `cmd/internal/obj/x86/asm6.go` | `MOVQ TLS, r` → `movq %gs:24, r` |
| `cmd/link/.../target.go` | `IsAros()` |
| `cmd/link/.../sym.go` | `Tlsoffset` 0 |
| `cmd/link/.../data.go` | `R_TLS_LE` resolution |

Two choices worth explaining. `CanUse1InsnTLS` must be **false**: `%gs:24`
holds a pointer *to* the g slot, not the slot, so the one-instruction form that
addresses g directly off a segment register is unavailable — the same situation
as Plan 9 and Windows. `Tlsoffset` is **0** because g sits at offset 0 of the
block, again as on Plan 9.

Verified without a runtime, by assembling `tests/tlsform.s` — `get_tls(BX)`
followed by `MOVQ g(BX), BX` — for `GOOS=aros`, and against the platforms it is
modelled on:

| GOOS | base load | g access |
|---|---|---|
| **aros** | `65488b1c2518000000` (`%gs:0x18`, no reloc) | `488b9b00000000` |
| plan9 | `488b1d00000000` + `R_PCREL:_privates` | `488b9b00000000` |
| windows | `R_PCREL:runtime.tls_g`, then `GS:0(BX)` | — |
| linux | `MOVQ FS:0, BX` (one-instruction form) | — |

The g access is byte-identical to Plan 9's. Only the base load differs, and
this one is cheaper: one segment-relative load with no relocation, where Plan 9
needs a PC-relative load of a global.

## Patch 2: routing the runtime onto the right shared code

Registers `aros/amd64` as a platform, regenerates `internal/goos`, and then
picks — from the implementations the Go tree already shares by build tag — the
ones that fit a system with no `mmap`, no futex, no Unix signal delivery and no
poller: `mem_sbrk`, `lock_sema`, `netpoll_stub`, and our own time and low-level
stubs rather than the generic Unix ones.

AROS keeps the *generated* allocator tables rather than Plan 9's empty slices;
that substitution is a space saving Plan 9 needs and AROS does not.

Eight build tags cut the undefined OS-layer symbols from **57 to 37**. Nothing
runs; this only means the compiler now fails in the right places.

## What remains

The runtime, and it is the bulk of the work. Measured against Plan 9's port as
the closest template:

| package | lines |
|---|---|
| `syscall` | 3,006 |
| `runtime` | 2,729 |
| `os` | 1,194 |
| `internal/poll` | 379 |
| `time` | 193 |
| rest | ~140 |
| **total** | **~10,100** |

`syscall` is both the largest piece and the one with no usable template: AROS
has no syscalls at all. Everything goes through SysBase/DOSBase vectors, i.e. C
calls, so the OS layer is closer in shape to Go's libc-based ports — darwin,
aix, solaris, windows — than to Plan 9's.

For memory, `mem_plan9.go`'s sbrk model maps onto `AllocMem`/`AllocVec`. For
the network poller, start with `netpoll_stub.go`, as Plan 9 does.

## Reproducing

```sh
git clone -b go1.27.0 https://go.googlesource.com/go
cd go && git am ../patches/0001-*.patch ../patches/0002-*.patch
cd src && ./make.bash

GOOS=aros GOARCH=amd64 ../bin/go tool asm -p tlsform -D GOARCH_amd64 \
    -I $PWD/runtime -o /tmp/t.o ../../tests/tlsform.s
../bin/go tool objdump /tmp/t.o
```

`-D GOARCH_amd64` is required because `go_tls.h` guards on it and `go tool asm`
does not predefine it when invoked directly. Without it `get_tls` is simply an
unrecognised instruction — on every GOOS, not just this one, which makes it
look like a bug in the port when it is not.

## Licence

Modifies Go source and is offered under the same terms, the
[Go BSD-style licence](https://go.dev/LICENSE).
