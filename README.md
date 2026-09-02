# go-aros — porting the Go gc toolchain to AROS x86_64

Nothing Go exists in AROS today. Checked before starting: no hits in
`aros-development-team/AROS`, `contrib`, `ports` or `external-sources`, and
none in `deadwood2/AROS` either. (`libgo` matches only Poppler's `goo/`
directory.) So this is a fresh port, and it collides with nobody.

**gccgo is not the way in.** `libgo/VERSION` reads `go1.18` in GCC 13, 14, 15
*and* master — frozen since 2023 — while our GCC 10.5 gives `go1.14.6`. Real
targets need far newer: Syncthing's `go.mod` asks for `go 1.26.2`. So the gc
toolchain it is.

## Why the surface is smaller than it looks

Two findings from reading the Go tree, both of which cut the estimate hard.

**TLS is one lowering point, not a scattered dependency.** `get_tls(r)` on
amd64 is the pseudo-instruction `MOVQ TLS, r` (`runtime/go_tls.h`), lowered in
exactly one place, `cmd/internal/obj/x86/asm6.go`. Plan 9's case there is a
single `MOV` from a global symbol, and `runtime·settls` on Plan 9 is a bare
`RET` — no segment register, no relocation, no kernel support. `g` itself lives
in **R14** under ABIInternal (`REGG = REG_R14`); TLS is only how `g` is
*recovered* at boundaries — thread entry, signal delivery, entry from C.

**External linking sidesteps the executable format.** AROS executables are
`ET_REL`, which Go's linker does not emit. `-linkmode=external` hands the final
link to a host linker, so `x86_64-aros-gcc` and the SDK's linker script do that
part and Go's linker never needs to learn the format.

The compiler is written in Go and cross-compiles, so the toolchain is built on
the Mac. Nothing has to run on AROS for the toolchain to exist.

## Status: the thread pointer lowering is done and checked

`aros-tls` landed, so the primitive exists. `patches/0001-*.patch` teaches the
Go toolchain about it — seven registration points, no runtime yet:

| file | change |
|---|---|
| `internal/syslist` | `aros` in `KnownOS` |
| `cmd/internal/objabi/head.go` | `Haros`, `Set()`, `String()` |
| `cmd/internal/obj/x86/obj6.go` | `ArosTLSOffset = 24`; `CanUse1InsnTLS` false; Plan 9's scale marker |
| `cmd/internal/obj/x86/asm6.go` | `MOVQ TLS, r` → `movq %gs:24, r` |
| `cmd/link/.../target.go` | `IsAros()` |
| `cmd/link/.../sym.go` | `Tlsoffset` 0 |
| `cmd/link/.../data.go` | `R_TLS_LE` resolution |

`CanUse1InsnTLS` has to be false: `%gs:24` holds a pointer *to* the g slot, not
the slot, so the one-instruction form that addresses g directly off a segment
is unavailable. `Tlsoffset` is 0 because g sits at offset 0 of the block. Both
match Plan 9.

Checked without a runtime, by assembling `tests/tlsform.s` — `get_tls(BX)`
followed by `MOVQ g(BX), BX` — with `GOOS=aros`:

```
65488b1c2518000000   MOVQ GS:0x18, BX
488b9b00000000       MOVQ 0(BX), BX     [3:7]R_TLS_LE
```

and against the platforms it is modelled on:

| GOOS | base load | g access |
|---|---|---|
| **aros** | `65488b1c2518000000` (`%gs:0x18`, no reloc) | `488b9b00000000` |
| plan9 | `488b1d00000000` + `R_PCREL:_privates` | `488b9b00000000` |
| windows | `R_PCREL:runtime.tls_g`, then `GS:0(BX)` | — |
| linux | `MOVQ FS:0, BX` (one-instruction form) | — |

The g access is byte-identical to Plan 9's. Only the base load differs, and
ours is cheaper: one segment-relative load with no relocation, where Plan 9
needs a PC-relative load of a global.

To reproduce: apply the patch to go1.27.0, `./make.bash`, then

```
GOOS=aros GOARCH=amd64 go tool asm -p tlsform -D GOARCH_amd64 \
    -I $GOROOT/src/runtime -o /tmp/t.o tests/tlsform.s
go tool objdump /tmp/t.o
```

`-D GOARCH_amd64` is needed because `go_tls.h` guards on it and `go tool asm`
does not predefine it when invoked directly; without it `get_tls` is simply an
unrecognised instruction, on every GOOS.

## What comes next

The runtime. Nothing above touches it, and it is the bulk of the work.

## Shape of the port

* **OS layer by library call, not syscall.** AROS has no syscalls; everything
  goes through SysBase/DOSBase vectors, i.e. C calls. Go already has libc-based
  ports — darwin, aix, solaris, windows — so `libcCall`-style transitions are a
  travelled path rather than a new invention.
* **Memory without mmap.** `mem_plan9.go` is the template: no reservation, brk
  shaped, mapped onto `AllocMem`/`AllocVec`.
* **Netpoll.** Start with `netpoll_stub.go`, as Plan 9 does.
* **Scale.** Plan 9's whole runtime port is 19 files and ~2700 lines. That is
  the honest yardstick, not "person-years".
