///////////////////////////////////////////
// hypervisorTwoStage.S
//
// Written: eoinoconnell04 17 September 2026
//
// Purpose: Pass/fail test of two-stage (VS-stage + G-stage) address
//          translation for ordinary guest loads, stores, and instruction
//          fetch issued from VS-mode (V=1). Each scenario builds one-level
//          (gigapage) page tables, enters VS-mode with mret, performs a load
//          or store through the fabricated guest address, and returns to
//          M-mode with an ecall. The M-mode handler checks mcause and the
//          returned data against the expected "canary" values.
//
//          Scenarios:
//            A. VS-stage Sv39,  G-stage Bare     (single-stage under V=1)
//            B. VS-stage Bare,  G-stage Sv39x4   (G-stage only)
//            C. VS-stage Sv39,  G-stage Sv39x4   (full two-stage)
//            D. Guest store through two-stage translation, checked from M-mode
//            E. G-stage fault on a load: expect load guest-page fault (21)
//               with mtval = GVA and mtval2 = GPA >> 2
//            F. VS-stage fault under two-stage: expect load page fault (13)
//            G. G-stage fault on instruction fetch: expect instruction
//               guest-page fault (20) with mtval2 = GPA >> 2
//            H. G-stage fault on a store: expect store guest-page fault (23)
//            I. HLV.D/HSV.D issued from M-mode (V=0) translate through the same
//               vsatp/hgatp tables with hstatus.SPVP privilege: a supervisor
//               (SPVP=1) HLV reads what scenario D stored, HSV stores through
//               two-stage translation, an HLV of an unmapped GPA is a load
//               guest-page fault, and an HLV with SPVP=0 (VU privilege) of a
//               supervisor page is an ordinary load page fault (13)
//            J. HLVX.WU requires execute permission: it succeeds on the RWX
//               page of scenario C, faults (13) on a read-only VS-stage
//               mapping of the same guest physical page where HLV.W succeeds
//
//          On failure the test writes tohost = (code << 1) | 1, where code
//          identifies the scenario (see FAIL_* below), so a failing run can be
//          diagnosed from the testbench "tohost write" message alone.
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
.equ CSR_MTVAL,         0x343
.equ CSR_MTVAL2,        0x34B
.equ CSR_HGATP,         0x680
.equ CSR_VSATP,         0x280
.equ CSR_SATP,          0x180

.equ CAUSE_VS_ECALL,    10
.equ CAUSE_LOAD_PF,     13
.equ CAUSE_INSTR_GPF,   20
.equ CAUSE_LOAD_GPF,    21
.equ CAUSE_STORE_GPF,   23

.equ MSTATUS_MPP_MASK,  0x0000000000001800
.equ MSTATUS_MPP_S,     0x0000000000000800
.equ MSTATUS_MPP_M,     0x0000000000001800
.equ MSTATUS_MPV,       0x0000008000000000
.equ MSTATUS_MIE,       0x0000000000000008

.equ GIGAMASK_INV,      0xFFFFFFFFC0000000  # ~(1GB-1): clears the gigapage-offset bits[29:0]
.equ GIGAOFF_MASK,      0x000000003FFFFFFF  # gigapage offset bits[29:0]
.equ VS_PTE_FLAGS,      0xCF                # D=1,A=1,G=0,U=0,X=1,W=1,R=1,V=1 (supervisor page)
.equ G_PTE_FLAGS,       0xDF                # D=1,A=1,G=0,U=1,X=1,W=1,R=1,V=1 (G-stage needs U=1)
.equ SATP_MODE_SV39,    0x8000000000000000  # satp/vsatp MODE field = 8 (Sv39)
.equ HGATP_MODE_SV39X4, 0x8000000000000000  # hgatp MODE field = 8 (Sv39x4)

# Failure codes (tohost = (code << 1) | 1)
.equ FAIL_A,            1
.equ FAIL_B,            2
.equ FAIL_C,            3
.equ FAIL_D,            4
.equ FAIL_E,            5
.equ FAIL_F,            6
.equ FAIL_G,            7
.equ FAIL_H,            8
.equ FAIL_I,            9
.equ FAIL_J,            10

.equ VS_PTE_FLAGS_RO,   0xC3                # D=1,A=1,G=0,U=0,X=0,W=0,R=1,V=1 (read-only supervisor page)
.equ GVA_J,             0x300000000         # VS index 12 -> GPA_C, read-only

.macro HLV_W rd, rs1
    .word 0x68004073 | (\rd << 7) | (\rs1 << 15)
.endm
.macro HLVX_WU rd, rs1
    .word 0x68304073 | (\rd << 7) | (\rs1 << 15)
.endm

.equ CSR_HSTATUS,       0x600
.equ HSTATUS_SPVP,      0x0000000000000100

# HLV.D rd, (rs1) and HSV.D rs2, (rs1): SYSTEM encodings, register numbers as operands
.macro HLV_D rd, rs1
    .word 0x6C004073 | (\rd << 7) | (\rs1 << 15)
.endm
.macro HSV_D rs1, rs2
    .word 0x6E004073 | (\rs1 << 15) | (\rs2 << 20)
.endm

# Guest virtual / guest physical bases used by the scenarios (gigapage-aligned)
.equ GVA_A,             0x140000000         # VS index 5
.equ GPA_B,             0x100000000         # G  index 4
.equ GVA_C,             0x180000000         # VS index 6
.equ GPA_C,             0x1C0000000         # G  index 7
.equ GVA_E,             0x200000000         # VS index 8 -> GPA_E (unmapped in G)
.equ GPA_E,             0x240000000         # G  index 9 (left invalid)
.equ GVA_F,             0x280000000         # VS index 10 (left invalid)
.equ GVA_G,             0x2C0000000         # VS index 11 -> GPA_G (unmapped in G)
.equ GPA_G,             0x300000000         # G  index 12 (left invalid)

# Install a gigapage leaf PTE: table[index] = (PA_gigabase >> 12 << 10) | flags
.macro SET_GIGA_PTE table, index, pa_reg, flags
    li   t1, GIGAMASK_INV
    and  t0, \pa_reg, t1
    srli t0, t0, 12
    slli t0, t0, 10
    li   t1, \flags
    or   t0, t0, t1
    la   t1, \table + (\index * 8)
    sd   t0, 0(t1)
.endm

# Enter VS-mode at \entry with the M-mode handler returning to \cont.
.macro ENTER_VS entry, cont, code
    la   t0, \cont
    la   t1, current_continue_pc
    sd   t0, 0(t1)
    li   t0, \code
    la   t1, current_fail_code
    sd   t0, 0(t1)
    la   t0, \entry
    csrw mepc, t0
    li   t0, MSTATUS_MPP_MASK | MSTATUS_MPV
    csrc CSR_MSTATUS, t0
    li   t0, MSTATUS_MPP_S | MSTATUS_MPV
    csrs CSR_MSTATUS, t0
    mret
.endm

.macro EXPECT_EQ reg, val, code
    li   t6, \val
    beq  \reg, t6, 1f
    li   a0, \code
    j    fail
1:
.endm

main:
    csrr s1, CSR_MTVEC
    la   t0, vs_trap_handler
    csrw CSR_MTVEC, t0

    # Mask interrupts for the VS-mode windows to keep them deterministic.
    li   t0, MSTATUS_MIE
    csrc CSR_MSTATUS, t0

    csrw CSR_SATP, zero

    #############################################################
    # Build all page tables up front.
    #
    # Every VS-stage and G-stage table identity-maps the gigapage holding
    # this program (index 2, 0x80000000-0xBFFFFFFF) so guest instruction
    # fetch, the guest stack, and the VS-stage page-table pages themselves
    # (which the walker reads through the G-stage) all resolve.
    #############################################################
    la   s2, main                      # PA of the program's gigapage

    # vs_table_a: index 2 identity, index 5 -> canary_a's gigapage
    SET_GIGA_PTE vs_table_a, 2, s2, VS_PTE_FLAGS
    la   s3, canary_a
    SET_GIGA_PTE vs_table_a, 5, s3, VS_PTE_FLAGS

    # g_table_b: index 2 identity, index 4 -> canary_b's gigapage
    SET_GIGA_PTE g_table_b, 2, s2, G_PTE_FLAGS
    la   s3, canary_b
    SET_GIGA_PTE g_table_b, 4, s3, G_PTE_FLAGS

    # vs_table_c: index 2 identity, index 6 -> GPA_C, index 8 -> GPA_E,
    #             index 11 -> GPA_G (E/G are deliberately unmapped in G-stage)
    SET_GIGA_PTE vs_table_c, 2, s2, VS_PTE_FLAGS
    li   s3, GPA_C
    SET_GIGA_PTE vs_table_c, 6, s3, VS_PTE_FLAGS
    li   s3, GPA_E
    SET_GIGA_PTE vs_table_c, 8, s3, VS_PTE_FLAGS
    li   s3, GPA_G
    SET_GIGA_PTE vs_table_c, 11, s3, VS_PTE_FLAGS
    li   s3, GPA_C
    SET_GIGA_PTE vs_table_c, 12, s3, VS_PTE_FLAGS_RO   # read-only alias of GPA_C for scenario J

    # g_table_c: index 2 identity, index 7 -> canary_c's gigapage
    SET_GIGA_PTE g_table_c, 2, s2, G_PTE_FLAGS
    la   s3, canary_c
    SET_GIGA_PTE g_table_c, 7, s3, G_PTE_FLAGS

    #############################################################
    # Scenario A: VS-stage Sv39, G-stage Bare.
    #############################################################
    csrw CSR_HGATP, zero
    la   t0, vs_table_a
    srli t0, t0, 12
    li   t1, SATP_MODE_SV39
    or   t0, t0, t1
    csrw CSR_VSATP, t0
    .word 0x22000073           # hfence.vvma x0, x0
    ENTER_VS scenario_a_entry, after_a, FAIL_A
after_a:
    EXPECT_EQ s4, CAUSE_VS_ECALL, FAIL_A
    EXPECT_EQ s5, 0x1111111111111111, FAIL_A

    #############################################################
    # Scenario B: VS-stage Bare, G-stage Sv39x4.
    #############################################################
    csrw CSR_VSATP, zero
    la   t0, g_table_b
    srli t0, t0, 12
    li   t1, HGATP_MODE_SV39X4
    or   t0, t0, t1
    csrw CSR_HGATP, t0
    .word 0x62000073           # hfence.gvma x0, x0
    ENTER_VS scenario_b_entry, after_b, FAIL_B
after_b:
    EXPECT_EQ s4, CAUSE_VS_ECALL, FAIL_B
    EXPECT_EQ s5, 0x2222222222222222, FAIL_B

    #############################################################
    # Scenario C: VS-stage Sv39 and G-stage Sv39x4 (full two-stage).
    #############################################################
    la   t0, vs_table_c
    srli t0, t0, 12
    li   t1, SATP_MODE_SV39
    or   t0, t0, t1
    csrw CSR_VSATP, t0
    la   t0, g_table_c
    srli t0, t0, 12
    li   t1, HGATP_MODE_SV39X4
    or   t0, t0, t1
    csrw CSR_HGATP, t0
    .word 0x22000073           # hfence.vvma x0, x0
    .word 0x62000073           # hfence.gvma x0, x0
    ENTER_VS scenario_c_entry, after_c, FAIL_C
after_c:
    EXPECT_EQ s4, CAUSE_VS_ECALL, FAIL_C
    EXPECT_EQ s5, 0x3333333333333333, FAIL_C

    #############################################################
    # Scenario D: guest store through two-stage translation (same tables
    # as C), then verify from M-mode with an ordinary physical load.
    #############################################################
    ENTER_VS scenario_d_entry, after_d, FAIL_D
after_d:
    EXPECT_EQ s4, CAUSE_VS_ECALL, FAIL_D
    la   t1, store_c
    ld   t2, 0(t1)
    EXPECT_EQ t2, 0x0123456789ABCDEF, FAIL_D

    #############################################################
    # Scenario E: load whose VS-stage mapping is valid but whose GPA has
    # no G-stage mapping. Expect load guest-page fault (21), mtval = GVA,
    # mtval2 = GPA >> 2.
    #############################################################
    ENTER_VS scenario_e_entry, after_e, FAIL_E
after_e:
    EXPECT_EQ s4, CAUSE_LOAD_GPF, FAIL_E
    EXPECT_EQ s6, GVA_E + 0x123, FAIL_E
    EXPECT_EQ s7, (GPA_E + 0x123) >> 2, FAIL_E

    #############################################################
    # Scenario F: load whose VS-stage PTE is invalid (index 10). Expect an
    # ordinary load page fault (13) with mtval = GVA, mtval2 = 0.
    #############################################################
    ENTER_VS scenario_f_entry, after_f, FAIL_F
after_f:
    EXPECT_EQ s4, CAUSE_LOAD_PF, FAIL_F
    EXPECT_EQ s6, GVA_F + 0x456, FAIL_F
    EXPECT_EQ s7, 0, FAIL_F

    #############################################################
    # Scenario G: jump to a GVA whose VS-stage mapping is valid but whose
    # GPA has no G-stage mapping. Expect instruction guest-page fault (20)
    # with mtval = GVA and mtval2 = GPA >> 2.
    #############################################################
    ENTER_VS scenario_g_entry, after_g, FAIL_G
after_g:
    EXPECT_EQ s4, CAUSE_INSTR_GPF, FAIL_G
    EXPECT_EQ s6, GVA_G + 0x100, FAIL_G
    EXPECT_EQ s7, (GPA_G + 0x100) >> 2, FAIL_G

    #############################################################
    # Scenario H: store whose GPA has no G-stage mapping. Expect store
    # guest-page fault (23), mtval = GVA, mtval2 = GPA >> 2.
    #############################################################
    ENTER_VS scenario_h_entry, after_h, FAIL_H
after_h:
    EXPECT_EQ s4, CAUSE_STORE_GPF, FAIL_H
    EXPECT_EQ s6, GVA_E + 0x200, FAIL_H
    EXPECT_EQ s7, (GPA_E + 0x200) >> 2, FAIL_H

    #############################################################
    # Scenario I: HLV.D/HSV.D from M-mode (V=0) through the scenario C tables.
    # hstatus.SPVP=1 gives the accesses VS (supervisor) privilege, which the
    # U=0 VS-stage PTEs require.
    #############################################################
    li   t0, HSTATUS_SPVP
    csrs CSR_HSTATUS, t0
    li   t1, GVA_C
    la   t2, store_c
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    add  t1, t1, t2            # t1 = GVA of store_c under the scenario C tables
    HLV_D 11, 6                # a1 = HLV.D (t1): value stored by scenario D
    EXPECT_EQ a1, 0x0123456789ABCDEF, FAIL_I
    li   t0, 0xFEDCBA9876543210
    HSV_D 6, 5                 # HSV.D t0, (t1)
    la   t2, store_c
    ld   t2, 0(t2)             # verify with an ordinary M-mode physical load
    EXPECT_EQ t2, 0xFEDCBA9876543210, FAIL_I

    # HLV.D of a GPA with no G-stage mapping: load guest-page fault, mtval = GVA, mtval2 = GPA >> 2
    la   t0, after_i_gpf
    la   t2, current_continue_pc
    sd   t0, 0(t2)
    li   t1, GVA_E + 0x300
    HLV_D 11, 6
after_i_gpf:
    EXPECT_EQ s4, CAUSE_LOAD_GPF, FAIL_I
    EXPECT_EQ s6, GVA_E + 0x300, FAIL_I
    EXPECT_EQ s7, (GPA_E + 0x300) >> 2, FAIL_I

    # HLV.D with SPVP=0 (VU privilege) of the supervisor (U=0) page: load page fault
    li   t0, HSTATUS_SPVP
    csrc CSR_HSTATUS, t0
    la   t0, after_i_pf
    la   t2, current_continue_pc
    sd   t0, 0(t2)
    li   t1, GVA_C
    la   t2, store_c
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    add  t1, t1, t2
    HLV_D 11, 6
after_i_pf:
    EXPECT_EQ s4, CAUSE_LOAD_PF, FAIL_I
    EXPECT_EQ s7, 0, FAIL_I

    #############################################################
    # Scenario J: HLVX.WU needs execute permission. GVA_C maps canary_c's
    # page RWX; GVA_J maps the same guest physical page read-only.
    #############################################################
    li   t0, HSTATUS_SPVP
    csrs CSR_HSTATUS, t0
    la   t2, canary_c
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    li   t1, GVA_C
    add  t1, t1, t2
    HLVX_WU 11, 6              # a1 = HLVX.WU (t1) on the RWX page
    EXPECT_EQ a1, 0x33333333, FAIL_J
    li   t1, GVA_J
    add  t1, t1, t2
    HLV_W 11, 6                # HLV.W on the read-only page succeeds
    EXPECT_EQ a1, 0x33333333, FAIL_J
    la   t0, after_j_pf
    la   t3, current_continue_pc
    sd   t0, 0(t3)
    HLVX_WU 11, 6              # HLVX.WU on the read-only page: load page fault
after_j_pf:
    EXPECT_EQ s4, CAUSE_LOAD_PF, FAIL_J
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    li   t6, GVA_J
    add  t6, t6, t2
    bne  s6, t6, fail_j        # mtval = GVA
    EXPECT_EQ s7, 0, FAIL_J
    j    1f
fail_j:
    li   a0, FAIL_J
    j    fail
1:
    li   t0, HSTATUS_SPVP
    csrc CSR_HSTATUS, t0

    csrw CSR_MTVEC, s1
    csrw CSR_VSATP, zero
    csrw CSR_HGATP, zero
    .word 0x22000073           # hfence.vvma x0, x0
    .word 0x62000073           # hfence.gvma x0, x0
    j done

# M-mode handler for the VS-mode windows: captures mcause/mtval/mtval2 and
# the guest's a1 into s4..s7, then returns to the scenario's continuation
# point in M-mode with V=0. Every trap returns to M-mode (never retries the
# faulting instruction) because the fault scenarios use addresses that are
# only meaningful under the guest's translation.
.align 4
vs_trap_handler:
    csrr s4, CSR_MCAUSE
    mv   s5, a1
    csrr s6, CSR_MTVAL
    csrr s7, CSR_MTVAL2
    la   t0, current_continue_pc
    ld   t0, 0(t0)
    csrw mepc, t0
    li   t0, MSTATUS_MPP_MASK | MSTATUS_MPV
    csrc CSR_MSTATUS, t0
    li   t0, MSTATUS_MPP_M
    csrs CSR_MSTATUS, t0
    mret

.align 4
scenario_a_entry:
    li   t1, GVA_A
    la   t2, canary_a
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    add  t1, t1, t2
    ld   a1, 0(t1)
    ecall

.align 4
scenario_b_entry:
    li   t1, GPA_B
    la   t2, canary_b
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    add  t1, t1, t2
    ld   a1, 0(t1)
    ecall

.align 4
scenario_c_entry:
    li   t1, GVA_C
    la   t2, canary_c
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    add  t1, t1, t2
    ld   a1, 0(t1)
    ecall

.align 4
scenario_d_entry:
    li   t1, GVA_C
    la   t2, store_c
    li   t3, GIGAOFF_MASK
    and  t2, t2, t3
    add  t1, t1, t2
    li   t0, 0x0123456789ABCDEF
    sd   t0, 0(t1)
    ld   a1, 0(t1)             # read back through the same translation
    ecall

.align 4
scenario_e_entry:
    li   t1, GVA_E + 0x123
    lb   a1, 0(t1)             # expect load guest-page fault
    ecall

.align 4
scenario_f_entry:
    li   t1, GVA_F + 0x456
    lb   a1, 0(t1)             # expect load page fault (VS-stage)
    ecall

.align 4
scenario_g_entry:
    li   t1, GVA_G + 0x100
    jr   t1                    # expect instruction guest-page fault
    ecall

.align 4
scenario_h_entry:
    li   t1, GVA_E + 0x200
    sw   t0, 0(t1)             # expect store guest-page fault
    ecall

fail:
    la t1, tohost
    slli t0, a0, 1
    ori  t0, t0, 1
    sw t0, 0(t1)
fail_loop:
    j fail_loop

.section .data
.align 3
canary_a:
    .dword 0x1111111111111111
canary_b:
    .dword 0x2222222222222222
canary_c:
    .dword 0x3333333333333333
store_c:
    .dword 0

current_continue_pc:
    .dword 0
current_fail_code:
    .dword 0

# Sv39x4 root tables: 2048 entries (16 KiB), must be 16 KiB aligned.
.align 14
g_table_b:
    .fill 2048, 8, 0
.align 14
g_table_c:
    .fill 2048, 8, 0

# Sv39 root tables: 512 entries (4 KiB), 4 KiB aligned.
.align 12
vs_table_a:
    .fill 512, 8, 0
.align 12
vs_table_c:
    .fill 512, 8, 0
