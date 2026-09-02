// The two halves of Go's thread-pointer access, isolated so the encoding can be
// checked without a runtime. On AROS this must assemble to
//
//     movq %gs:0x18, %rbx      ; the kernel-published TLS base
//     movq (%rbx), %rbx        ; g, at offset 0 of it
//
// with no relocation left over: the address is absolute in the segment, and g
// sits at offset 0 because the linker's Tlsoffset is 0 for this platform.
#include "textflag.h"
#include "go_tls.h"

TEXT ·loadg(SB), NOSPLIT, $0-8
	get_tls(BX)
	MOVQ	g(BX), BX
	MOVQ	BX, ret+0(FP)
	RET
