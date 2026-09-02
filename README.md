# go-aros

**A Go program runs on AROS x86_64.** Prints, schedules a goroutine, sends over
a channel, allocates on the GC heap, and exits cleanly. This is a bringup tree,
not a finished port — much of the standard library is untested and the OS layer
is minimal — but the core runtime is up.

```
hello from Go on AROS
goroutine and heap check: 42
```

(a `println` and a `<-ch` from a goroutine, on a live AROS One under QEMU)

## Where it stands

| | |
|---|---|
| Thread pointer on AROS | **done** — see [aros-tls](https://github.com/tomaszstaniak/aros-tls) |
| `GOOS=aros` and `MOVQ TLS, r` lowering | **done, verified by disassembly** |
| `package runtime` compiles | **yes** |
| Linking to an AROS `ET_REL`, `LoadSeg` accepts it | **yes, measured** |
| Runtime starts: sched, channels, GC alloc, clean exit | **yes, measured** |
| Standard library beyond the basics | **untested** |
| `fmt`, `os` file I/O, `net`, goroutine preemption | **not yet** |

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

## Patch 3: stubs, to reach the linker early

The 37 OS-layer symbols are implemented as stubs with correct signatures that
`throw`. That ordering is deliberate. The unverified assumption underneath this
whole port is that `-linkmode=external` can hand an ET_REL executable to
`x86_64-aros-gcc`; if it cannot, Go's linker has to learn AROS's executable
format, which is a much larger job. Stubbing costs a few hundred lines and
answers that question before the real OS layer is written.

Three things were needed to get that far, and each is a real finding rather
than boilerplate:

* **`Haros` is treated as ELF** in `archinit` and `asmb2`, so the linker writes
  a relocatable object for the host linker — but `R_TLS_LE` is deliberately
  *still resolved internally*. `g` is reached through a pointer the kernel
  publishes in the `%gs` block, not through ELF TLS, so handing that relocation
  to `x86_64-aros-gcc` would ask it for something it cannot do.
* **`-fPIC` and `-pthread` are dropped for `GOOS=aros`** in `cmd/go`, replaced
  by `-mcmodel=large -mno-red-zone`. AROS builds everything `ET_REL`, and its
  gcc driver rejects `-pthread` outright.
* **The note functions came straight back out** of the stub file: `lock_sema.go`
  already supplies them once `aros` is on its build tag.

## Patch 4: the external link works

The size mismatch was the two relocation passes disagreeing: `relocsym`
(counting) had the AROS exception for `R_TLS_LE`, `extreloc` (emitting) did
not, so `elfrelocsect` wrote 239 relocations it had not budgeted for — exactly
5736 bytes at 24 per relocation. Once both passes agree, Go's linker writes
`go.o` and hands it to `x86_64-aros-gcc`.

Three more things stood between that and an output file:

* `-rdynamic` — rejected by the AROS gcc driver, and meaningless for an
  `ET_REL` that nobody `dlopen`s. Skipped in `hostlink`.
* `runtime/cgo` needed an AROS thread file. `pthread_unix.c` cannot be reused:
  AROS has **no `sigfillset` and no `pthread_sigmask`**, because signals there
  are Exec's per-task bits rather than Unix masks. `gcc_aros_amd64.c` is that
  file with the mask dance removed; `pthread_getattr_np`, which AROS does
  provide, keeps the stack-bound path.
* `rt0_aros_amd64.s` is two jumps and `runtime·settls` is a bare `RET`, as on
  Plan 9: the kernel publishes the thread pointer, so the runtime has nothing
  to install.

The result, for `package main; func main() {}`:

```
$ CGO_ENABLED=1 GOOS=aros GOARCH=amd64 CC=x86_64-aros-gcc \
      go build -ldflags="-linkmode=external -extld=x86_64-aros-gcc" -o hello .
$ x86_64-aros-readelf -h hello | grep Type
  Type:                              REL (Relocatable file)
```

3.4 MB, header identical to a known-good AROS binary, **231** `mov %gs:0x18,%r14`
loads in the final text — the thread pointer landing in Go's `g` register — and
no ELF TLS relocations. (A grep for "TLS" finds 23, but they are plain
`R_X86_64_64` to symbols that merely have "tls" in their *names*: `tls_sem`,
`tlskeys`, `runtime.settls`.)

And the measurement that matters, on a running AROS One, using the sandbox's
`segdump` — which `LoadSeg`s a file without executing it and reads back the
first `movabs` immediate the startup code will pass to `OpenLibrary`:

```
first movabs rdi at +0x3e imm=00000004bcb00f0 -> "dos.library"
hunk  1: hdr=000000004bca4be4 size=46936  ...
hunk  2: hdr=000000004bd3a7e4 size=461563 ...
...
hunk 11: hdr=000000004ccf4e84 size=52     ...
```

`"dos.library"` means the `.text` relocations were applied; a stripped or
mis-linked AROS binary shows `(null)` there and dies in `strlen` before
`main`. Twelve hunks loaded. So the assumption this port was built on is now a
fact: **AROS's own loader accepts what Go plus the AROS toolchain produce.**

Known leftover: the linker still emits `runtime.tlsg` into a `.tbss` section.
Nothing references it and `LoadSeg` did not object, but it should not be
there.

The binary does not *run* — every OS-layer function is still a stub — and
running it is not informative yet, since `write1` is a no-op and `exit`
throws, so the first `throw` has no way to say anything.

## What remains

The runtime is up but thin. Known gaps, roughly in order:

* **Signals and preemption.** `preemptMSupported` is false, so a tight loop
  with no function calls will not yield. Signals are stubbed.
* **The rest of the OS layer.** File descriptors beyond raw write to 1/2,
  directory reads, process control — `syscall` and `os` are barely started.
* **`goenvs`** passes an empty environment; the C startup's argv/envp is not
  wired in.
* **Netpoll** is the Plan-9-style stub: blocking I/O only, no poller.

Sized against Plan 9's port as the closest template:

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
