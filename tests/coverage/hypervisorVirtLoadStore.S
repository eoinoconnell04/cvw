///////////////////////////////////////////
// hypervisorVirtLoadStore.S
//
// Written: eoinoconnell04 17 September 2026
//
// Purpose: Unit test for ordinary (non-HLV/HSV) load/store and instruction
//          fetch issued directly by guest code running with mstatus.MPV=1
//          (VS-mode), with VS-stage and G-stage translation both Bare.
//
//          hypervisorLoadStore.S covers the explicit HLV/HLVX/HSV path used
//          by HS-mode to access guest memory on the guest's behalf. This
//          test instead covers the ordinary LSU/IFU data and fetch path
//          taken when the guest itself issues normal lb/lh/lw/ld/sb/sh/sw/sd
//          and control-flow instructions while V=1, relying on the
//          satp->vsatp mux (csr.sv) to fall through correctly when both
//          stages are Bare.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
////////////////////////////////////////////////////////////////////////////////////////////////

// load code to initialize stack, handle interrupts, terminate
#include "WALLY-init-lib.h"

.equ CSR_MSTATUS,       0x300
.equ CSR_MTVEC,         0x305
.equ CSR_MCAUSE,        0x342
.equ CSR_HGATP,         0x680
.equ CSR_VSATP,         0x280
.equ CSR_SATP,          0x180

.equ CAUSE_VS_ECALL,    10

.equ MSTATUS_MPP_MASK,  0x0000000000001800
.equ MSTATUS_MPP_S,     0x0000000000000800
.equ MSTATUS_MPP_M,     0x0000000000001800
.equ MSTATUS_MPV,       0x0000008000000000
.equ MSTATUS_MIE,       0x0000000000000008

.macro CHECK_EQ actual_reg, expect_val
    li t6, \expect_val
    bne \actual_reg, t6, fail
.endm

main:
    csrr s1, CSR_MTVEC

    # Keep VS-stage and G-stage translation Bare. This test only covers the
    # ordinary (non-HLV/HSV) data and fetch path in the Bare/Bare case;
    # non-Bare two-stage translation belongs with the G-stage walker work.
    csrw CSR_SATP, zero
    csrw CSR_VSATP, zero
    csrw CSR_HGATP, zero

    # Mask interrupts for the VS-mode block below. Stable VS/VU normal
    # execution is a known limitation (see README), so keep the window small
    # and deterministic: m_trap_handler_virt below treats any trap other
    # than the closing VS ecall as an immediate failure, instead of silently
    # skipping it the way the shared library handler does.
    li t0, MSTATUS_MIE
    csrc CSR_MSTATUS, t0

    la t0, m_trap_handler_virt
    csrw CSR_MTVEC, t0

    # Enter VS-mode with mret: MPP=S and MPV=1.
    la t0, vs_entry
    csrw mepc, t0
    li t0, MSTATUS_MPP_MASK | MSTATUS_MPV
    csrc CSR_MSTATUS, t0
    li t0, MSTATUS_MPP_S | MSTATUS_MPV
    csrs CSR_MSTATUS, t0
    mret

after_vs_block:
    csrw CSR_MTVEC, s1

    # Confirm the guest's store is visible through an ordinary M-mode load,
    # the same way hypervisorLoadStore.S verifies its U-mode HSV store.
    la t1, virt_store
    ld t2, 0(t1)
    CHECK_EQ t2, 0x0123456789ABCDEF

    j done

.align 4
m_trap_handler_virt:
    csrr t0, CSR_MCAUSE
    li t1, CAUSE_VS_ECALL
    bne t0, t1, fail    # any trap besides the expected closing VS ecall is a failure

    la t0, after_vs_block
    csrw mepc, t0
    li t0, MSTATUS_MPP_MASK | MSTATUS_MPV
    csrc CSR_MSTATUS, t0
    li t0, MSTATUS_MPP_M
    csrs CSR_MSTATUS, t0
    mret

.align 4
vs_entry:
    # Ordinary stores and loads issued directly by guest (VS-mode) code,
    # exercising the LSU/DMMU data path under V=1 rather than the explicit
    # HLV/HLVX/HSV instructions covered by hypervisorLoadStore.S.
    la t1, virt_store

    li t0, 0xAA
    sb t0, 0(t1)
    lbu t2, 0(t1)
    CHECK_EQ t2, 0xAA

    li t0, 0xBEEF
    sh t0, 0(t1)
    lhu t2, 0(t1)
    CHECK_EQ t2, 0xBEEF

    li t0, 0x89ABCDEF
    sw t0, 0(t1)
    lwu t2, 0(t1)
    CHECK_EQ t2, 0x89ABCDEF

    li t0, 0x0123456789ABCDEF
    sd t0, 0(t1)
    ld t2, 0(t1)
    CHECK_EQ t2, 0x0123456789ABCDEF

    # Ordinary loads of a preinitialized pattern, checking sign/zero
    # extension the same way hypervisorLoadStore.S does for HLV.
    la t1, virt_data
    lb  t0, 0(t1)
    CHECK_EQ t0, -128
    lbu t0, 0(t1)
    CHECK_EQ t0, 0x80
    lh  t0, 0(t1)
    CHECK_EQ t0, 0xFFFFFFFFFFFF8080
    lhu t0, 0(t1)
    CHECK_EQ t0, 0x8080
    lw  t0, 0(t1)
    CHECK_EQ t0, 0xFFFFFFFF81348080
    lwu t0, 0(t1)
    CHECK_EQ t0, 0x81348080
    ld  t0, 0(t1)
    CHECK_EQ t0, 0x8877665581348080

    # Exercise ordinary instruction fetch across a call/return while V=1.
    jal ra, virt_helper
    CHECK_EQ t0, 0x1234

    li a0, 0
    ecall               # CAUSE_VS_ECALL traps to m_trap_handler_virt, restores V=0

virt_helper:
    li t0, 0x1234
    ret

fail:
    la t1, tohost
    li t0, 3
    sw t0, 0(t1)
fail_loop:
    j fail_loop

.section .data
.align 3
virt_data:
    .dword 0x8877665581348080
virt_store:
    .dword 0
