# Multidomain (OCaml 5 SMP) on Unikraft

This records what it takes to run a genuinely multidomain OCaml 5
unikernel (one that calls `Domain.spawn` / `Domain.join`) on the
qemu-arm64 backend, and why each change is needed. The OCaml runtime
itself needs no source change; the blockers are all in the Unikraft
backend configuration and, for an SMP guest, in the Unikraft source.

## Root cause: the backend caps domains to one

The backend environment bakes in `OCAMLRUNPARAM=d=1`
(`CONFIG_LIBPOSIX_ENVIRON_ENVP1`). `d` is OCaml's `max_domains`: with
`d=1` the runtime reserves exactly one domain slot, so the first
`Domain.spawn` finds no free slot (`next_free_domain()` returns NULL in
`runtime/domain.c`) and raises `Failure "failed to allocate domain"`.
The main domain works, so the failure only shows once a second domain is
spawned.

Fix: set `d` to the number of domains the guest should support. The
`qemu-arm64-musl-smp` config uses `d=4`, matching its logical-CPU count.

```
CONFIG_LIBPOSIX_ENVIRON_ENVP1="OCAMLRUNPARAM=d=4"
```

With this alone the domains run and join correctly (the workers are
scheduled cooperatively on the boot CPU; `recommended_domain_count`
stays 1). Bringing the domains up on separate cores additionally needs
the SMP config and the Unikraft source fixes below.

## SMP config (`dummykernel/config/opts/smp`, `qemu-arm64-musl-smp.fullconfig`)

```
CONFIG_UKPLAT_LCPU_MAXCOUNT=4
CONFIG_HAVE_SMP=y
```

`olddefconfig` then selects `CONFIG_LIBUKINTCTLR_GICV3=y`. Boot such a
guest under QEMU with a GICv3 machine and matching vCPU count, e.g.
`-machine virt,gic-version=3 -smp 4`. (The cooperative-domain case above
boots on plain `-machine virt` with any `-smp`.)

## Unikraft source fixes (opam-installed tree, not yet a fork patch)

These live in `$(UNIKRAFT)` = the opam-installed
`lib/unikraft/` tree, which has no patch mechanism here, so they are
re-applied by hand after `opam reinstall`. All three are general (not
OCaml-specific) and are candidates to upstream to unikraft/unikraft.

### 1. GICv3 secondary boot order (`plat/kvm/arm/setup.c`)

The GICv3 redistributor access (`GIC_RDIST_REG`, via
`lcpu_get_current()->idx`) needs `tpidr_el1`, which `lcpu_init` sets.
The original order probed the interrupt controller before `lcpu_init`,
so an SMP GICv3 guest hit an assertion in `lcpu.c` at boot. Run
`lcpu_init(lcpu_get_bsp())` before `uk_intctlr_probe()`:

```c
	/* Initialize logical boot CPU first: it sets tpidr_el1, which the GICv3
	 * redistributor access (lcpu_get_current) needs during the interrupt
	 * controller probe below. */
	rc = lcpu_init(lcpu_get_bsp());
	if (unlikely(rc))
		UK_CRASH("Failed to initialize bootstrapping CPU: %d\n", rc);

	/* Initialize interrupt controller */
	rc = uk_intctlr_probe();
	if (unlikely(rc))
		UK_CRASH("Could not initialize the IRQ controller: %d\n", rc);
```

### 2. GCC 15 C23 constructor call (`lib/ukboot/boot.c`)

A zero-argument constructor is called with two arguments; under GCC 15
(C23, where `()` is a prototype, not "unspecified args") that is a hard
error. Cast to the called signature:

```c
		((void (*)(int, char **))*ctorfn)(argc, argv);
```

### 3. GCC 15 arm64 build flags (`arch/arm/arm64/Makefile.uk`)

GCC 15 promotes `-Wint-conversion` and `-Wincompatible-pointer-types`
to errors and defaults to a newer C standard than the Unikraft arm64
sources assume. Add, after `ARCHFLAGS += -D__ARM_64__`:

```make
ARCHFLAGS     += -Wno-int-conversion -Wno-incompatible-pointer-types -std=gnu11
ISR_ARCHFLAGS += -Wno-int-conversion -Wno-incompatible-pointer-types -std=gnu11
```

## Verifying

Build the mono `unikernels/bin/smp` example against this backend and
boot it:

```
mrg build -t unikraft unikernels/bin/smp
mrg run   -t unikraft unikernels/bin/smp
# ... joined: main=1346269 A=2178309 B=3524578 -- multidomain OK
```
