# Coverage Tests

## Hypervisor Coverage Tests

The hypervisor coverage tests are targeted checks for the currently implemented
parts of Wally's RISC-V Hypervisor extension support. They are intended to run
on `rv64gch` against ImperasDV lockstep.

These are not full H-extension architectural compliance tests. Two-stage
(VS-stage + G-stage) translation, guest-page faults with `htval`/`mtval2`, and
HLV/HSV through two-stage translation are covered by `hypervisorTwoStage.S`
(see below), but only with one-level (gigapage) tables and without ImperasDV
lockstep, which is unavailable in this environment.

<details>
<summary>Common build and ImperasDV setup</summary>

Build an individual test from the repository root:

```sh
source ./setup.sh
make -C tests/coverage <test>.elf <test>.elf.objdump
```

Run an individual test with ImperasDV lockstep:

```sh
wsim rv64gch --elf tests/coverage/<test>.elf --lockstepverbose > <test>.log 2>&1
```

A successful lockstep run should report:

```text
Mismatches            : 0
```

The test should write `tohost = 1`, then stop at the normal coverage-test self
loop / testbench stop point. If a self-check fails, these tests write
`tohost = 3` with a store word so the testbench terminates instead of repeatedly
writing `tohost`.

The `rv64gch` ImperasDV run needs a local configuration file at:

```text
config/deriv/rv64gch/imperas.ic
```

`config/deriv` is ignored by git, so first generate the derived configurations
from the repository root:

```sh
make deriv
```

Then create the local Imperas config if needed. Copy and paste the contents of
`config/rv64gc/imperas.ic` into `config/deriv/rv64gch/imperas.ic`, then make
these edits:

1. Change the variant line from `--variant RV64GCK` to `--variant RV64GCH`.
2. Add `--override cpu/GEILEN=1`.
3. Remove the crypto override block, because this target is `GCH`, not `GCK`:

```text
# Crypto extensions
--override cpu/Zkr=F
--override cpu/Zksed=F
--override cpu/Zksh=F
--override cpu/mnoise_undefined=T
```

If the destination directory or file does not exist yet, create it first:

```sh
mkdir -p config/deriv/rv64gch
touch config/deriv/rv64gch/imperas.ic
```

Then paste in the contents from `config/rv64gc/imperas.ic` and make the edits
above.

</details>

<details>
<summary>hypervisorUnitTests.S</summary>

`hypervisorUnitTests.S` is a broad unit test for implemented H-extension CSR,
aliasing, interrupt CSR, and privileged decode behavior.

What it tests:

- Hypervisor CSR read/write and WARL behavior from M-mode:
  - `mtinst`, `mtval2`
  - `hstatus`, `hedeleg`, `mideleg`, `hideleg`, `hcounteren`, `hgeie`
  - `htval`, `htinst`, `hgatp`
  - `vsstatus`, `vstvec`, `vsscratch`, `vsepc`, `vscause`, `vstval`, `vsatp`
- Hypervisor interrupt CSR aliasing:
  - GEILEN=1 behavior for `hstatus.VGEIN`, `hgeie`, and `mideleg`.SGEI
  - `hie` writes reflected in `mie`
  - `vsie` writes reflected through delegated `hie`/`mie` bits
  - `hip`, `hvip`, and `vsip` delegated virtual interrupt aliases
- Timer and environment CSRs:
  - `vstimecmp`
  - `menvcfg` / `henvcfg`
  - `htimedelta`
- Read-only / illegal CSR behavior:
  - `hgeip` write attempts trap as illegal; pending state is driven by the
    test MMIO source
- HS-mode execution:
  - enters HS using the shared `WALLY-init-lib.h` ecall privilege-change helper
  - executes `hfence.gvma x0, x0` in HS
  - drives guest external interrupt 1 through the local TrickBox HGEIP source
    and checks HS-level SGEI delivery
  - returns to M-mode and verifies a marker register to confirm the HS block ran
- Hypervisor privileged instruction decode:
  - legal `hfence.vvma x0, x0` in M-mode
  - legal `hfence.gvma x0, x0` in M-mode
  - illegal HFENCE-like encoding with nonzero `rd`, expecting `mcause = 2`

Known limitations:

- VS/VU execution is not included yet. Earlier experiments could enter
  virtualized state but were not stable enough for this coverage test because
  guest execution, trap behavior, and two-stage translation support are still
  incomplete.
- The test is primarily for implemented CSR behavior, RVVI/Imperas lockstep
  visibility, and privileged decode coverage.

Build:

```sh
source ./setup.sh
make -C tests/coverage hypervisorUnitTests.elf hypervisorUnitTests.elf.objdump
```

Run:

```sh
wsim rv64gch --elf tests/coverage/hypervisorUnitTests.elf --lockstepverbose > hypervisorUnitTests.log 2>&1
```

Useful generated files:

- `tests/coverage/hypervisorUnitTests.elf`
- `tests/coverage/hypervisorUnitTests.elf.objdump`
- `tests/coverage/hypervisorUnitTests.elf.memfile`

The guest-external interrupt check uses the CLINT-range TrickBox sidecar:
`TRICKEN[6]` is written at `0x0200A010`, then HGEIP bit 1 is driven through the
slot at `0x0200C000`.

In `--lockstepverbose` output, the HS-mode test can be identified by the
instruction trace around `hs_mode_entry`, where Imperas prints the privilege
label as `Supervisor`:

```text
0x000000008000545a(hs_mode_entry): Supervisor ...
0x000000008000545e(hs_mode_entry+4): Supervisor 62000073 hfence.gvma x0,x0
```

In this test context, `Supervisor` with virtualization mode `V=0` corresponds
to HS-mode.

</details>

<details>
<summary>hypervisorInterrupts.S</summary>

`hypervisorInterrupts.S` is a focused companion test for implemented
H-extension interrupt behavior.

What it tests:

- `GEILEN=1` interrupt-visible CSR behavior for `hstatus.VGEIN`, `hgeie`, and
  read-only-one `mideleg`.SGEI
- `hie` / `mie` aliasing for SGEIE and VS interrupt-enable bits
- `vsie` delegated interrupt-enable aliasing
- `hip`, `hvip`, and `vsip` delegated virtual interrupt-pending aliases
- read-only `hgeip` CSR behavior
- HS-mode delivery of software-injected VSSI, VSTI, and VSEI through `hvip`
- HS-mode supervisor guest external interrupt delivery through the local
  TrickBox HGEIP source

Build:

```sh
source ./setup.sh
make -C tests/coverage hypervisorInterrupts.elf hypervisorInterrupts.elf.objdump
```

Run:

```sh
wsim rv64gch --elf tests/coverage/hypervisorInterrupts.elf --lockstepverbose > hypervisorInterrupts.log 2>&1
```

The same local ImperasDV `GEILEN=1` override and HGEIP TrickBox addresses
described for `hypervisorUnitTests.S` apply to this test.

</details>

<details>
<summary>hypervisorExceptions.S</summary>

`hypervisorExceptions.S` is a focused companion test for hypervisor exception
classification and trap CSR side effects.

What it tests:

- VS-mode virtual-instruction traps for H CSR access, HFENCE, HLV,
  CBO/envcfg, SATP under `hstatus.VTVM`, and SRET under `hstatus.VTSR`
- `mtval` contents for those virtual-instruction traps
- HS-mode illegal-instruction delegation for `hfence.gvma` when
  `mstatus.TVM=1`
- `stval` contents for the delegated HS illegal-instruction trap

Build:

```sh
source ./setup.sh
make -C tests/coverage hypervisorExceptions.elf hypervisorExceptions.elf.objdump
```

Run:

```sh
wsim rv64gch --elf tests/coverage/hypervisorExceptions.elf --lockstepverbose > hypervisorExceptions.log 2>&1
```

</details>

<details>
<summary>hypervisorLoadStore.S</summary>

`hypervisorLoadStore.S` is a focused test for the implemented HLV, HLVX, and
HSV execution path with both VS-stage and G-stage translation set to Bare. This
matches the current first-pass RTL support for HLV/HLVX/HSV and intentionally
avoids non-Bare guest translation behavior.

Setup:

- Clears `satp`, `vsatp`, and `hgatp`, so ordinary, VS-stage, and G-stage
  translation are Bare.
- Sets `hstatus.SPVP=1`, so HLV/HLVX/HSV use VS-level effective privilege.
- Uses hand-encoded `.word` macros for HLV/HLVX/HSV so the test does not depend
  on assembler mnemonic support.

What it tests:

- M-mode HLV and HLVX loads from one test doubleword:
  - `hlv.b`
  - `hlv.bu`
  - `hlv.h`
  - `hlv.hu`
  - `hlv.w`
  - `hlv.wu`
  - `hlv.d`
  - `hlvx.hu`
  - `hlvx.wu`
- M-mode HSV stores and ordinary load readback:
  - `hsv.b`
  - `hsv.h`
  - `hsv.w`
  - `hsv.d`
- U-mode HLV/HSV execution when `hstatus.HU=1`:
  - enters U-mode with the shared privilege-change helper
  - executes `hlv.bu`
  - executes `hsv.b`
  - returns to M-mode and verifies the U-mode store updated memory

Known limitations:

- Non-Bare VS-stage and G-stage translation, guest-page faults, and
  `mtval2` / `htval` reporting are covered separately by
  `hypervisorTwoStage.S` (scenario I for HLV/HSV).
- `htinst` / `mtinst` trap transform behavior is not covered.
- HLVX execute-permission behavior through page tables and PMP is not covered.
- MPRV/MPV interactions for ordinary load/store instructions are not covered.

Build:

```sh
source ./setup.sh
make -C tests/coverage hypervisorLoadStore.elf hypervisorLoadStore.elf.objdump
```

Run:

```sh
wsim rv64gch --elf tests/coverage/hypervisorLoadStore.elf --lockstepverbose > hypervisorLoadStore.log 2>&1
```

</details>

<details>
<summary>hypervisorVirtLoadStore.S</summary>

`hypervisorVirtLoadStore.S` is a focused test for ordinary (non-HLV/HSV)
load/store and instruction fetch issued directly by guest code running with
`mstatus.MPV=1` (VS-mode), with both VS-stage and G-stage translation set to
Bare. `hypervisorLoadStore.S` covers the explicit HLV/HLVX/HSV path used by
HS-mode to access guest memory on the guest's behalf; this test instead
covers the ordinary LSU/IFU path taken when the guest itself issues normal
`lb`/`lh`/`lw`/`ld`/`sb`/`sh`/`sw`/`sd` and control-flow instructions while
`V=1`. It relies on the `satp`->`vsatp` mux in `csr.sv` falling through
correctly to a physical-address passthrough when both stages are Bare.

Setup:

- Clears `satp`, `vsatp`, and `hgatp`, so ordinary, VS-stage, and G-stage
  translation are Bare.
- Masks `mstatus.MIE` before entering the VS-mode block and installs a
  minimal local M-mode trap handler (`m_trap_handler_virt`) that treats any
  trap other than the expected closing VS-mode ecall as an immediate
  failure, rather than silently skipping it the way the shared
  `WALLY-init-lib.h` handler does. This is deliberate: the README above
  notes that stable VS/VU normal execution is a known limitation, so this
  test is written to fail loudly on any unexpected trap instead of masking
  one.

What it tests:

- Ordinary byte/half/word/double stores and readback loads to a single test
  location, issued directly from VS-mode
- Ordinary sign- and zero-extending loads (`lb`, `lbu`, `lh`, `lhu`, `lw`,
  `lwu`, `ld`) of a preinitialized pattern from VS-mode
- Ordinary instruction fetch across a `jal`/`ret` call while `V=1`
- Return to M-mode via a VS-mode `ecall` (`mcause = 10`), and that the
  guest's store is visible through an ordinary M-mode load afterward

Known limitations:

- Non-Bare VS-stage and G-stage translation are covered separately by
  `hypervisorTwoStage.S`.
- U-mode-under-virtualization (VU-mode) is not covered; only VS-mode.
- Interrupts are masked for the VS-mode block, so this does not cover
  interrupt behavior during ordinary guest execution.

Build:

```sh
source ./setup.sh
make -C tests/coverage hypervisorVirtLoadStore.elf hypervisorVirtLoadStore.elf.objdump
```

Run:

```sh
wsim rv64gch --elf tests/coverage/hypervisorVirtLoadStore.elf --lockstepverbose > hypervisorVirtLoadStore.log 2>&1
```

</details>

<details>
<summary>hypervisorTwoStage.S</summary>

`hypervisorTwoStage.S` is a pass/fail test of two-stage (VS-stage + G-stage)
address translation for ordinary guest loads, stores, and instruction fetch
issued from VS-mode (`V=1`). Each scenario builds one-level (gigapage) page
tables, enters VS-mode with `mret`, performs an access through a fabricated
guest address, and returns to M-mode with an `ecall`; the M-mode handler
then checks `mcause`, `mtval`, `mtval2`, and the data the guest read.

Scenarios:

- A: VS-stage Sv39, G-stage Bare (single-stage translation under `V=1`)
- B: VS-stage Bare, G-stage Sv39x4 (G-stage only)
- C: VS-stage Sv39 and G-stage Sv39x4 (full two-stage: VS-stage page-table
  reads themselves go through the G-stage)
- D: guest store through two-stage translation, verified from M-mode
- E: load with a valid VS-stage mapping but no G-stage mapping: expects a
  load guest-page fault (21) with `mtval` = GVA and `mtval2` = GPA >> 2
- F: load with an invalid VS-stage PTE under two-stage translation: expects
  an ordinary load page fault (13) with `mtval2` = 0
- G: jump to a GVA with no G-stage mapping: expects an instruction
  guest-page fault (20) with `mtval2` = GPA >> 2
- H: store with no G-stage mapping: expects a store guest-page fault (23)
- I: HLV.D/HSV.D from M-mode (`V=0`) through the scenario C tables with
  `hstatus.SPVP=1`; an HLV of an unmapped GPA (load guest-page fault with
  `mtval2`); and an HLV with `SPVP=0` of a supervisor page (load page fault)

On failure the test writes `tohost = (code << 1) | 1`, where `code` is the
scenario number (A=1 ... I=9), so the failing scenario can be read from the
testbench `tohost write` message.

How two-stage translation is implemented (see the header of `src/mmu/hptw.sv`
for the walker-level description):

- `csr.sv` exports HS-level and VS-level `satp`/`vsatp`, `hgatp`,
  `MXR`/`SUM`, and envcfg `PBMTE`/`ADUE` separately. The IMMU, DMMU, and
  walker choose the effective virtualization mode per access: `V` for
  fetches; `V`, `mstatus.MPV` under `MPRV`, or 1 for HLV/HLVX/HSV for data.
- TLB entries are tagged with `{V, VMID}` in addition to `{ASID, VPN}`, so
  guest and hypervisor translations of the same virtual address coexist.
- The walker runs a nested G-stage walk (Sv39x4/Sv48x4/Sv57x4) for every
  VS-stage PTE address and for the final guest physical address, and writes
  the TLB with one merged entry (supervisor physical page, the smaller page
  size, ANDed permissions, `A` set, `D` ANDed). A/D updates on merged
  entries are handed back to the walker so the right stage is updated or
  faulted.
- G-stage faults are guest-page faults (causes 20/21/23); `tval` gets the
  guest virtual address and `htval`/`mtval2` get the guest physical address
  shifted right by 2. VS-stage faults are checked before the final G-stage
  translation and remain ordinary page faults.

Known limitations:

- HLVX.HU/HLVX.WU are translated like ordinary HLV loads: the
  execute-permission check that distinguishes them is not implemented.
- `vsstatus.MXR` can relax reads of a merged entry whose G-stage page is
  execute-only even when the HS-level `MXR` is clear.
- With `vsatp` Bare, guest physical addresses wider than the configuration's
  virtual address width raise a guest-page fault instead of translating.
- `htinst`/`mtinst` are still written as zero.

Notes:

- VS-stage PTEs use `U=0` because VS-mode is a supervisor mode: an S-mode
  fetch or (with `SUM=0`) data access to a `U=1` page is an ordinary
  improper-privilege page fault. G-stage PTEs use `U=1` because G-stage
  accesses are always checked as user-level accesses.
- Every table identity-maps the gigapage holding the program (index 2) so
  that guest instruction fetch and the VS-stage page tables themselves
  resolve through the G-stage.

Build:

```sh
source ./setup.sh
make -C tests/coverage hypervisorTwoStage.elf hypervisorTwoStage.elf.objdump
```

Run (no lockstep):

```sh
wsim rv64gch --elf tests/coverage/hypervisorTwoStage.elf
```

The testbench prints `tohost write: value = 0x1` on success. Add
`--define "+define+TRACEPC"` to print every retired instruction and trap.

</details>
