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

## What it is blocked on

Go's `get_tls` must produce a per-thread pointer with no function call, in
contexts with no `g` and no usable stack. AROS has no such primitive today:
`FindTask(NULL)` is a library call, `__thread` lowers to
`__emutls_get_address` plus a `pthread_getspecific`, and the `%gs` block —
readable from userspace, `dpl = 3` — is per-CPU and holds only globals.
`struct ExecBase` has no `ThisTask` field at all; it went away with the SMP
rework.

That is why **[aros-tls](../aros-tls) comes first**: it adds the missing
primitive in a handful of lines in the dispatcher. This port does not start
until that lands and is verified.

## Shape of the port, once unblocked

* **OS layer by library call, not syscall.** AROS has no syscalls; everything
  goes through SysBase/DOSBase vectors, i.e. C calls. Go already has libc-based
  ports — darwin, aix, solaris, windows — so `libcCall`-style transitions are a
  travelled path rather than a new invention.
* **Memory without mmap.** `mem_plan9.go` is the template: no reservation, brk
  shaped, mapped onto `AllocMem`/`AllocVec`.
* **Netpoll.** Start with `netpoll_stub.go`, as Plan 9 does.
* **Scale.** Plan 9's whole runtime port is 19 files and ~2700 lines. That is
  the honest yardstick, not "person-years".
