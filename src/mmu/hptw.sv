///////////////////////////////////////////
// hptw.sv
//
// Written: tfleming@hmc.edu 2 March 2021
// Modified:  david_harris@hmc.edu 18 July 2021 cleanup and simplification
//            kmacsaigoren@hmc.edu 1 June 2021
//            implemented SV48 on top of SV39. This included, adding a level of the FSM for the extra page number segment
//            adding support for terapage encoding, and for setting the HPTWAdr using the new level,
//            adding the internal SvMode signal
//
//            implemented SV57 on top of SV48, SV39. This included, adding a level of the FSM for the extra page number segment
//            adding support for petapage encoding, and for setting the HPTWAdr using the new level,
//            adding the internal SvMode signal
//
//            eoinoconnell04 17 September 2026: hypervisor two-stage translation. Added a nested
//            G-stage (SvXXx4) walk: every VS-stage page-table access and the final guest physical
//            address are translated through hgatp, and the TLB is written with one merged entry.
// Purpose: Hardware Page Table Walker
//
// Documentation: RISC-V System on Chip Design
//
// Two-stage translation (hypervisor extension) overview:
//   * A walk is "virtualized" when V=1 (or MPRV/MPV or HLV/HSV for data). Stage 1 then
//     uses vsatp and produces guest physical addresses (GPAs); if hgatp is not Bare the
//     GPAs are translated by the G-stage (Sv39x4/Sv48x4/Sv57x4, or Sv32x4).
//   * The G-stage walk is a second copy of the level states (G4_ADR..G0_RD, GLEAF,
//     GUPDATE_PTE). It is entered for three purposes: an implicit read of a VS-stage PTE
//     (returns to the L*_RD state that reads the PTE at the supervisor physical address),
//     an implicit write of a VS-stage PTE for an A/D update (returns to UPDATE_PTE), or
//     the final translation of the guest physical address (writes the TLB and returns to IDLE).
//   * The TLB receives one merged entry: PPN = supervisor physical page, page size = the
//     smaller of the two stages, permissions = AND of both stages (G-stage read may be
//     relaxed by the HS-level MXR), A is always set (the walker updated or faulted on both
//     stages), D = AND of both stages. Because merged A/D bits cannot say which stage needs
//     updating, the TLB hands any such access back to the walker (see tlbcontrol.sv).
//   * G-stage faults are guest-page faults (causes 20/21/23) and report the faulting GPA
//     (right-shifted by 2) for htval/mtval2. VS-stage faults are ordinary page faults and
//     are checked before the final G-stage translation, as the spec's algorithm requires.
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwgroup/cvw
//
// Copyright (C) 2021 Harvey Mudd College & Oklahoma State University
//
// Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software
// is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT
// OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
///////////////////////////////////////////

module hptw import cvw::*;  #(parameter cvw_t P) (
  input  logic              clk, reset,
  input  logic [P.XLEN-1:0] SATP_REGW,              // HS-level satp: includes SATP.MODE to determine number of levels in page table
  input  logic [P.XLEN-1:0] VSATP_REGW,             // vsatp: VS-stage translation for virtualized walks
  input  logic [P.XLEN-1:0] HGATP_REGW,             // hgatp: G-stage translation for virtualized walks
  input  logic              VirtModeW,              // current virtualization mode V
  input  logic              MSTATUS_MPV,            // effective V for data accesses when mstatus.MPRV=1
  input  logic [P.XLEN-1:0] PCSpillF,               // addresses to translate
  input  logic [P.XLEN+1:0] IEUAdrExtM,             // addresses to translate
  input  logic [1:0]        MemRWM, AtomicM,
  // system status
  input  logic              STATUS_MXR, STATUS_SUM, STATUS_MPRV,
  input  logic [1:0]        STATUS_MPP,
  input  logic              VSSTATUS_MXR, VSSTATUS_SUM, // vsstatus bits applied to VS-stage translation
  input  logic              HSTATUS_SPVP,           // HLV/HLVX/HSV effective privilege: 0=VU, 1=VS
  input  logic              HLVHSVLegalM,           // HLV/HLVX/HSV access in Memory stage: translate as if V=1
  input  logic              ENVCFG_PBMTE,           // Svpbmt enable (HS level and G-stage)
  input  logic              VSENVCFG_PBMTE,         // Svpbmt enable (VS-stage)
  input  logic              ENVCFG_ADUE,            // HPTW A/D Update enable (HS level and G-stage)
  input  logic              VSENVCFG_ADUE,          // HPTW A/D Update enable (VS-stage)
  input  logic [1:0]        PrivilegeModeW,
  input  logic [P.XLEN-1:0] ReadDataM,              // page table entry from LSU
  input  logic [P.XLEN-1:0] WriteDataM,
  input  logic              DCacheBusStallM,           // stall from LSU
  input  logic [2:0]        Funct3M,
  input  logic [6:0]        Funct7M,
  input  logic              ITLBMissOrUpdateAF,
  input  logic              DTLBMissOrUpdateDAM,
  input  logic              FlushW,
  input  logic [3:0]        CMOpM,
  output logic [P.XLEN-1:0] PTE,                    // page table entry to TLBs (merged entry for two-stage walks)
  output logic [2:0]        PageType,               // page type to TLBs (merged page size for two-stage walks)
  output logic              ITLBWriteF, DTLBWriteM, // write TLB with new entry
  output logic [1:0]        PreLSURWM,
  output logic [P.XLEN+1:0] IHAdrM,
  output logic [P.XLEN-1:0] IHWriteDataM,
  output logic [1:0]        LSUAtomicM,
  output logic [2:0]        LSUFunct3M,
  output logic [6:0]        LSUFunct7M,
  output logic [3:0]        LSUCMOpM,
  output logic              HPTWFlushW,
  output logic              SelHPTW,
  output logic              HPTWStall,
  input  logic              LSULoadAccessFaultM, LSUStoreAmoAccessFaultM,
  input  logic              LSULoadPageFaultM, LSUStoreAmoPageFaultM,
  output logic              LoadAccessFaultM, StoreAmoAccessFaultM, HPTWInstrAccessFaultF,
  output logic              LoadPageFaultM, StoreAmoPageFaultM, HPTWInstrPageFaultF,
  output logic              LoadGuestPageFaultM, StoreAmoGuestPageFaultM, HPTWInstrGuestPageFaultF, // G-stage faults
  output logic [P.XLEN-1:0] HPTWGPAM                // guest physical address of a guest-page fault >> 2, valid with the fault
);

  typedef enum logic [4:0] {L0_ADR, L0_RD,
          L1_ADR, L1_RD,
          L2_ADR, L2_RD,
          L3_ADR, L3_RD,
          L4_ADR, L4_RD,
          LEAF, IDLE, UPDATE_PTE,
          FAULT,
          G0_ADR, G0_RD,                 // G-stage walk states, mirroring the stage-1 states
          G1_ADR, G1_RD,
          G2_ADR, G2_RD,
          G3_ADR, G3_RD,
          G4_ADR, G4_RD,
          GLEAF, GUPDATE_PTE} statetype;
  localparam [1:0] GIMPLICIT_RD = 2'd0, GIMPLICIT_WR = 2'd1, GFINAL = 2'd2; // why the G-stage walk was entered

  localparam GPA_BITS = (P.XLEN == 32) ? P.PA_BITS : P.XLEN;    // guest physical addresses: 34 bits for Sv32x4, up to 64 for RV64

  logic                     DTLBWalk; // register TLBs translation miss requests
  logic [P.PPN_BITS-1:0]    BasePageTablePPN;
  logic [P.PPN_BITS-1:0]    CurrentPPN;
  logic                     Executable, Writable, Readable, Valid, PTE_U, PTE_A, PTE_D;
  logic                     Misaligned, MegapageMisaligned;
  logic                     ValidPTE, LeafPTE, ValidLeafPTE, ValidNonLeafPTE;
  logic                     StartWalk;
  logic                     TLBMissOrUpdateDA;
  logic                     PRegEn;
  logic [2:0]               NextPageType;
  logic [P.SVMODE_BITS-1:0] SvMode;
  logic [P.XLEN-1:0]        TranslationVAdr;
  logic [P.XLEN-1:0]        StartTranslationVAdr;   // address of the walk about to start (DTLBWalk not yet registered)
  logic [P.XLEN-1:0]        PTEReg;                 // page table entry most recently read (or updated)
  logic [P.XLEN-1:0]        NextPTE, NextPTE2;
  logic                     UpdatePTE;
  logic                     HPTWUpdateDA;
  logic [P.PA_BITS-1:0]     HPTWReadAdr;
  logic [P.PA_BITS-1:0]     Stage1ReadAdr;          // {PPN, VPN, 0} of the stage-1 PTE for the current level
  logic                     SelHPTWAdr;
  logic [P.XLEN+1:0]        HPTWAdrExt;
  logic                     LSUAccessFaultM;
  logic [P.PA_BITS-1:0]     HPTWAdr;
  logic [1:0]               HPTWRW;
  logic [2:0]               HPTWSize; // 32 or 64 bit access
  statetype                 WalkerState, NextWalkerState, InitialWalkerState;
  logic                     HPTWLoadAccessFault, HPTWStoreAmoAccessFault, HPTWInstrAccessFault;
  logic                     HPTWLoadAccessFaultDelay, HPTWStoreAmoAccessFaultDelay, HPTWInstrAccessFaultDelay;
  logic                     HPTWLoadPageFault, HPTWStoreAmoPageFault, HPTWInstrPageFault;
  logic                     HPTWLoadPageFaultDelay, HPTWStoreAmoPageFaultDelay, HPTWInstrPageFaultDelay;
  logic                     HPTWLoadGuestPageFault, HPTWStoreAmoGuestPageFault, HPTWInstrGuestPageFault;
  logic                     HPTWLoadGuestPageFaultDelay, HPTWStoreAmoGuestPageFaultDelay, HPTWInstrGuestPageFaultDelay;
  logic                     TakeHPTWFault;
  logic                     PBMTFaultM;
  logic                     DAUFaultM;
  logic                     PBMTOrDAUFaultM;
  logic                     HPTWFaultM;
  logic                     StartWalkVirt;          // walk about to start from IDLE is virtualized (uses vsatp/hgatp)
  logic                     WalkVirt;               // walk in progress is virtualized (registered at walk start)
  logic [P.XLEN-1:0]        EffSATP;                // stage-1 address translation register for this walk
  logic [P.SVMODE_BITS-1:0] StartSvMode;            // stage-1 mode of the walk about to start
  logic                     EffMXR, EffSUM, EffADUE, EffPBMTE; // status/envcfg controls applied to stage-1 translation
  statetype                 StartInitialWalkerState; // first state of the walk about to start
  // permission checking
  logic                     ReadAccess, WriteAccess;
  logic                     InvalidRead, InvalidWrite, InvalidOp;
  logic                     UpperBitsUnequal, UpperBitsUnequalD;
  logic                     OtherPageFault;
  logic [1:0]               EffectivePrivilegeMode;
  logic                     ImproperPrivilege;
  logic                     SetDirty, VSSetDirty;
  logic [P.XLEN-1:0]        AccessedPTE;
  logic                     LeafMisaligned;         // stage-1 leaf superpage has nonzero low PPN bits
  // G-stage
  logic                     GStageEn;               // walk is virtualized and hgatp is not Bare
  logic                     TwoStage;               // VS-stage and G-stage both active
  logic                     GOnly;                  // VS-stage Bare, G-stage active
  logic                     StartGOnly;             // walk about to start is G-stage only
  logic [P.SVMODE_BITS-1:0] GMode;
  logic [P.PPN_BITS-1:0]    GBasePPN;
  logic                     InGWalk;                // walker is in a G-stage state
  logic                     GTop;                   // walker is at the top level of the G-stage table (SvXXx4: 4x larger root)
  logic                     GTopADR;
  logic                     EnterGWalk;             // walker is about to enter the G-stage walk
  statetype                 GInitialWalkerState;
  logic [GPA_BITS-1:0]      GPAReg, NextGPA;        // guest physical address being translated by the G-stage
  logic [GPA_BITS-1:0]      VSPTEGPAReg;            // guest physical address of the current VS-stage PTE
  logic [GPA_BITS-1:0]      FinalGPA;               // guest physical address from the VS-stage leaf
  logic                     GPAUpperBitsNonzero;    // GPA has nonzero bits above the G-stage width: guest-page fault
  logic [1:0]               GPurpose, NextGPurpose;
  statetype                 ReturnState, ReturnStateVal; // L*_RD state to resume after an implicit read
  logic [P.PA_BITS-1:0]     SPA, SPAReg;            // supervisor physical address produced by the G-stage
  logic [P.PPN_BITS-1:0]    SPAPPN, MaskedSPAPPN;
  logic [P.XLEN-1:0]        VSPTEReg;               // VS-stage leaf PTE saved across the final G-stage walk
  logic [2:0]               S1PageType;             // page type of the stage-1 (or single-stage) walk
  logic [2:0]               GPageType, NextGPageType, MinPageType;
  logic                     GReadNeeded, GWriteNeeded, GExecNeeded;
  logic                     GInvalidRead, GInvalidWrite, GInvalidExec;
  logic                     GDAMissing, GOtherFault, GLeafFault, GUpdateDA, GSetDirty, GLeafMisaligned;
  logic                     VSOtherFault, VSLeafFault, VSDAMissing;
  logic                     GuestFaultM, VSLeafFaultM;
  logic                     RestoreVSPTE;
  logic [P.XLEN-1:0]        MergedPTE;
  logic                     BadBitsVS, BadBitsG;    // reserved/PBMT/NAPOT encoding faults of a leaf PTE
  logic                     TLBWriteCond;
  logic                     GFinalWrite;            // GLEAF is completing the final translation

  // map hptw access faults onto either the original LSU load/store fault or instruction access fault
  assign LSUAccessFaultM         = LSULoadAccessFaultM | LSUStoreAmoAccessFaultM;
  assign PBMTOrDAUFaultM         = PBMTFaultM | DAUFaultM;
  assign HPTWFaultM              = LSUAccessFaultM | PBMTOrDAUFaultM;
  assign HPTWLoadAccessFault     = LSUAccessFaultM & DTLBWalk & MemRWM[1] & ~MemRWM[0];
  assign HPTWStoreAmoAccessFault = LSUAccessFaultM & DTLBWalk & (MemRWM[0] | (|CMOpM));
  assign HPTWInstrAccessFault    = LSUAccessFaultM & ~DTLBWalk;
  // Non-leaf PTE encoding faults belong to the stage being walked; VS-stage leaf faults are
  // page faults; anything from the G-stage is a guest-page fault.
  assign VSLeafFaultM            = (WalkerState == LEAF) & TwoStage & VSLeafFault;
  assign GuestFaultM             = (InGWalk & PBMTOrDAUFaultM) | ((WalkerState == GLEAF) & GLeafFault) | (GTopADR & GPAUpperBitsNonzero);
  assign HPTWLoadPageFault       = ((PBMTOrDAUFaultM & ~InGWalk) | VSLeafFaultM) & DTLBWalk & MemRWM[1] & ~MemRWM[0];
  assign HPTWStoreAmoPageFault   = ((PBMTOrDAUFaultM & ~InGWalk) | VSLeafFaultM) & DTLBWalk & (MemRWM[0] | (|CMOpM));
  assign HPTWInstrPageFault      = ((PBMTOrDAUFaultM & ~InGWalk) | VSLeafFaultM) & ~DTLBWalk;
  assign HPTWLoadGuestPageFault     = GuestFaultM & DTLBWalk & MemRWM[1] & ~MemRWM[0];
  assign HPTWStoreAmoGuestPageFault = GuestFaultM & DTLBWalk & (MemRWM[0] | (|CMOpM));
  assign HPTWInstrGuestPageFault    = GuestFaultM & ~DTLBWalk;

  flopr #(9) HPTWAccesFaultReg(clk, reset, {HPTWLoadAccessFault, HPTWStoreAmoAccessFault, HPTWInstrAccessFault,
                                            HPTWLoadPageFault, HPTWStoreAmoPageFault, HPTWInstrPageFault,
                                            HPTWLoadGuestPageFault, HPTWStoreAmoGuestPageFault, HPTWInstrGuestPageFault},
                               {HPTWLoadAccessFaultDelay, HPTWStoreAmoAccessFaultDelay, HPTWInstrAccessFaultDelay,
                                HPTWLoadPageFaultDelay, HPTWStoreAmoPageFaultDelay, HPTWInstrPageFaultDelay,
                                HPTWLoadGuestPageFaultDelay, HPTWStoreAmoGuestPageFaultDelay, HPTWInstrGuestPageFaultDelay});

  assign TakeHPTWFault = WalkerState != IDLE;

  // Improve timing by taking HPTW faults off critical path because these are multicycle operations anyway
  assign LoadAccessFaultM      = TakeHPTWFault ? HPTWLoadAccessFaultDelay : LSULoadAccessFaultM;
  assign StoreAmoAccessFaultM  = TakeHPTWFault ? HPTWStoreAmoAccessFaultDelay : LSUStoreAmoAccessFaultM;
  assign HPTWInstrAccessFaultF = TakeHPTWFault ? HPTWInstrAccessFaultDelay : 1'b0;
  assign LoadPageFaultM        = TakeHPTWFault ? HPTWLoadPageFaultDelay : LSULoadPageFaultM;
  assign StoreAmoPageFaultM    = TakeHPTWFault ? HPTWStoreAmoPageFaultDelay : LSUStoreAmoPageFaultM;
  assign HPTWInstrPageFaultF   = TakeHPTWFault ? HPTWInstrPageFaultDelay : 1'b0;
  assign LoadGuestPageFaultM      = TakeHPTWFault & HPTWLoadGuestPageFaultDelay;
  assign StoreAmoGuestPageFaultM  = TakeHPTWFault & HPTWStoreAmoGuestPageFaultDelay;
  assign HPTWInstrGuestPageFaultF = TakeHPTWFault & HPTWInstrGuestPageFaultDelay;
  // GPAReg holds the faulting address through the FAULT state; report it as htval/mtval2 encode it
  if (P.XLEN == 64) assign HPTWGPAM = {2'b00, GPAReg[P.XLEN-1:2]};
  else              assign HPTWGPAM = GPAReg[GPA_BITS-1:2];

  // Effective translation controls for this walk. Data walks are virtualized when V=1,
  // when mstatus.MPRV=1 with MPV=1, or for HLV/HLVX/HSV; instruction walks follow V.
  // The decision is registered at walk start (like DTLBWalk) so that the walker's
  // address does not depend combinationally on the DTLB miss that starts the walk;
  // the combinational StartWalkVirt is used only to pick the first walker state.
  if (P.H_SUPPORTED) begin: effvirt
    logic DataVirt;
    assign DataVirt = HLVHSVLegalM | (STATUS_MPRV ? MSTATUS_MPV : VirtModeW);
    assign StartWalkVirt = DTLBMissOrUpdateDAM ? DataVirt : VirtModeW;
    flopenr #(1) WalkVirtReg(clk, reset, StartWalk, StartWalkVirt, WalkVirt);
    assign EffSATP  = WalkVirt ? VSATP_REGW : SATP_REGW;
    assign StartSvMode = StartWalkVirt ? VSATP_REGW[P.XLEN-1:P.XLEN-P.SVMODE_BITS] : SATP_REGW[P.XLEN-1:P.XLEN-P.SVMODE_BITS];
    assign EffMXR   = WalkVirt ? (VSSTATUS_MXR | STATUS_MXR) : STATUS_MXR; // HS-level MXR applies to both stages
    assign EffSUM   = WalkVirt ? VSSTATUS_SUM : STATUS_SUM;
    assign EffADUE  = WalkVirt ? VSENVCFG_ADUE : ENVCFG_ADUE;
    assign EffPBMTE = WalkVirt ? VSENVCFG_PBMTE : ENVCFG_PBMTE;
    // G-stage is active for virtualized walks whenever hgatp is not Bare
    assign GMode    = HGATP_REGW[P.XLEN-1:P.XLEN-P.SVMODE_BITS];
    assign GBasePPN = HGATP_REGW[P.PPN_BITS-1:0];
    assign GStageEn = WalkVirt & (GMode != P.NO_TRANSLATE[P.SVMODE_BITS-1:0]);
    assign TwoStage = GStageEn & (SvMode != P.NO_TRANSLATE[P.SVMODE_BITS-1:0]);
    assign GOnly    = GStageEn & (SvMode == P.NO_TRANSLATE[P.SVMODE_BITS-1:0]);
    assign StartGOnly = StartWalkVirt & (GMode != P.NO_TRANSLATE[P.SVMODE_BITS-1:0]) & (StartSvMode == P.NO_TRANSLATE[P.SVMODE_BITS-1:0]);
  end else begin: effvirt_noh
    assign StartWalkVirt = 1'b0;
    assign WalkVirt = 1'b0;
    assign EffSATP  = SATP_REGW;
    assign StartSvMode = SATP_REGW[P.XLEN-1:P.XLEN-P.SVMODE_BITS];
    assign EffMXR   = STATUS_MXR;
    assign EffSUM   = STATUS_SUM;
    assign EffADUE  = ENVCFG_ADUE;
    assign EffPBMTE = ENVCFG_PBMTE;
    assign GMode    = '0;
    assign GBasePPN = '0;
    assign GStageEn = 1'b0;
    assign TwoStage = 1'b0;
    assign GOnly    = 1'b0;
    assign StartGOnly = 1'b0;
  end

  // Extract bits from CSRs and inputs
  assign SvMode = EffSATP[P.XLEN-1:P.XLEN-P.SVMODE_BITS];
  assign BasePageTablePPN = EffSATP[P.PPN_BITS-1:0];
  assign TLBMissOrUpdateDA = DTLBMissOrUpdateDAM | ITLBMissOrUpdateAF;

  // Determine which address to translate
  mux2 #(P.XLEN) vadrmux(PCSpillF, IEUAdrExtM[P.XLEN-1:0], DTLBWalk, TranslationVAdr);
  mux2 #(P.XLEN) startvadrmux(PCSpillF, IEUAdrExtM[P.XLEN-1:0], DTLBMissOrUpdateDAM, StartTranslationVAdr);
  assign CurrentPPN = PTEReg[P.PPN_BITS+9:10];

  // State flops
  flopenr #(1) TLBMissMReg(clk, reset, StartWalk, DTLBMissOrUpdateDAM, DTLBWalk); // when walk begins, record whether it was for DTLB (or record 0 for ITLB)
  assign RestoreVSPTE = (WalkerState == UPDATE_PTE) & TwoStage & (NextWalkerState == LEAF); // bring the VS-stage leaf back after its A/D update
  assign PRegEn = HPTWRW[1] & ~DCacheBusStallM | UpdatePTE | (NextWalkerState == IDLE) | RestoreVSPTE;
  assign NextPTE2 = (NextWalkerState == IDLE) ? '0 : NextPTE;
  flopenr #(P.XLEN) PTEReg1(clk, reset, PRegEn, NextPTE2, PTEReg); // Capture page table entry from data cache

  // Assign PTE descriptors common across all XLEN values
  // For non-leaf PTEs, D, A, U bits are reserved and ignored.  They do not cause faults while walking the page table
  assign {PTE_D, PTE_A} = PTEReg[7:6];
  assign {PTE_U, Executable, Writable, Readable, Valid} = PTEReg[4:0];
  assign LeafPTE = Executable | Writable | Readable;
  assign ValidPTE = Valid & ~(Writable & ~Readable);
  assign ValidLeafPTE = ValidPTE & LeafPTE;
  assign ValidNonLeafPTE = Valid & ~LeafPTE;
  if(P.XLEN == 64) assign PBMTFaultM = ValidNonLeafPTE & (|PTEReg[62:61]);
  else assign PBMTFaultM = 1'b0;
  assign DAUFaultM = ValidNonLeafPTE & (|PTEReg[7:6] | PTEReg[4]);

  ///////////////////////////////////////////
  // Permission checks on the PTE in PTEReg
  ///////////////////////////////////////////

  assign WriteAccess = MemRWM[0]; // implies | (|AtomicM);
  assign ReadAccess = MemRWM[1];
  assign VSSetDirty = ~PTE_D & DTLBWalk & (WriteAccess | CMOpM[3]);

  // DTLB walks use MPP mode when MPRV is 1, and hstatus.SPVP for HLV/HLVX/HSV
  if (P.H_SUPPORTED) begin: effpriv_h
    assign EffectivePrivilegeMode = (DTLBWalk & HLVHSVLegalM) ? {1'b0, HSTATUS_SPVP} :
                                    DTLBWalk ? (STATUS_MPRV ? STATUS_MPP : PrivilegeModeW) : PrivilegeModeW;
  end else begin: effpriv_noh
    assign EffectivePrivilegeMode = DTLBWalk ? (STATUS_MPRV ? STATUS_MPP : PrivilegeModeW) : PrivilegeModeW;
  end
  assign ImproperPrivilege = ((EffectivePrivilegeMode == P.U_MODE) & ~PTE_U) |
                             ((EffectivePrivilegeMode == P.S_MODE) & PTE_U & (~EffSUM & DTLBWalk));

  // Check for page faults
  vm64check #(P) vm64check(.SATP_MODE(EffSATP[P.XLEN-1:P.XLEN-P.SVMODE_BITS]), .VAdr(TranslationVAdr),
    .SV39Mode(), .SV48Mode(), .UpperBitsUnequal);
  // This register is not functionally necessary, but improves the critical path.
  flopr #(1) upperbitsunequalreg(clk, reset, UpperBitsUnequal, UpperBitsUnequalD);
  assign InvalidRead = ReadAccess & ~Readable & (~EffMXR | ~Executable);
  assign InvalidWrite = WriteAccess & ~Writable;
  assign InvalidOp = DTLBWalk ? (InvalidRead | InvalidWrite) : ~Executable;
  assign OtherPageFault = ImproperPrivilege | InvalidOp | UpperBitsUnequalD | Misaligned | ~Valid;

  // Full stage-1 leaf check used for two-stage walks, where the walker (not the TLB) must
  // raise VS-stage page faults before the final G-stage translation is attempted.
  if (P.H_SUPPORTED) begin: vsleafcheck
    logic ImproperPrivilegeFull, InvalidReadFull, InvalidWriteFull, InvalidOpFull;
    // Instruction walks: S may not execute U pages; data walks: S may access U pages only with SUM
    assign ImproperPrivilegeFull = ((EffectivePrivilegeMode == P.U_MODE) & ~PTE_U) |
                                   ((EffectivePrivilegeMode == P.S_MODE) & PTE_U & (~DTLBWalk | ~EffSUM));
    assign InvalidReadFull  = (ReadAccess | (|CMOpM[2:0])) & ~Readable & (~EffMXR | ~Executable);
    assign InvalidWriteFull = (WriteAccess | CMOpM[3]) & ~Writable;
    assign InvalidOpFull    = DTLBWalk ? (InvalidReadFull | InvalidWriteFull) : ~Executable;
    assign VSOtherFault = ImproperPrivilegeFull | InvalidOpFull | UpperBitsUnequalD | LeafMisaligned | ~Valid |
                          (Writable & ~Readable) | BadBitsVS;
    assign VSDAMissing  = ~PTE_A | VSSetDirty;
    assign VSLeafFault  = VSOtherFault | (VSDAMissing & ~(P.SVADU_SUPPORTED & EffADUE));
  end else begin: vsleafcheck_noh
    assign VSOtherFault = 1'b0;
    assign VSDAMissing  = 1'b0;
    assign VSLeafFault  = 1'b0;
  end

  // Reserved, PBMT, and NAPOT encoding checks on a leaf PTE (RV64 only)
  if (P.XLEN == 64) begin: badbits64
    logic [1:0] PTE_PBMT;
    logic       PTE_N, BadNAPOT, BadReserved;
    assign PTE_N = PTEReg[63];
    assign PTE_PBMT = PTEReg[62:61];
    assign BadReserved = |PTEReg[60:54];
    assign BadNAPOT = PTE_N & (~P.SVNAPOT_SUPPORTED | (PTEReg[13:10] != 4'b1000));
    assign BadBitsVS = ((PTE_PBMT != 2'b00) & ~(P.SVPBMT_SUPPORTED & EffPBMTE)) | (PTE_PBMT == 2'b11) | BadNAPOT | BadReserved;
    assign BadBitsG  = ((PTE_PBMT != 2'b00) & ~(P.SVPBMT_SUPPORTED & ENVCFG_PBMTE)) | (PTE_PBMT == 2'b11) | BadNAPOT | BadReserved;
  end else begin: badbits32
    assign BadBitsVS = 1'b0;
    assign BadBitsG  = 1'b0;
  end

  // G-stage leaf checks: all G-stage accesses are user-level (U must be set), permissions
  // are checked for the purpose of the walk, and the HS-level MXR may make executable
  // pages readable. Missing A/D bits are updated when Svadu is enabled for the G-stage
  // (menvcfg.ADUE) and are otherwise guest-page faults.
  if (P.H_SUPPORTED) begin: gleafcheck
    assign GReadNeeded  = (GPurpose == GIMPLICIT_RD) | ((GPurpose == GFINAL) & DTLBWalk & (ReadAccess | (|CMOpM[2:0])));
    assign GWriteNeeded = (GPurpose == GIMPLICIT_WR) | ((GPurpose == GFINAL) & DTLBWalk & (WriteAccess | CMOpM[3]));
    assign GExecNeeded  = (GPurpose == GFINAL) & ~DTLBWalk;
    assign GInvalidRead  = GReadNeeded & ~Readable & (~STATUS_MXR | ~Executable);
    assign GInvalidWrite = GWriteNeeded & ~Writable;
    assign GInvalidExec  = GExecNeeded & ~Executable;
    assign GSetDirty     = ~PTE_D & GWriteNeeded;
    assign GDAMissing    = ~PTE_A | GSetDirty;
    assign GOtherFault   = ~Valid | (Writable & ~Readable) | ~PTE_U | GLeafMisaligned | BadBitsG |
                           GInvalidRead | GInvalidWrite | GInvalidExec;
    assign GLeafFault    = GOtherFault | (GDAMissing & ~(P.SVADU_SUPPORTED & ENVCFG_ADUE));
    assign GUpdateDA     = ValidLeafPTE & GDAMissing & P.SVADU_SUPPORTED & ENVCFG_ADUE & ~GOtherFault;
  end else begin: gleafcheck_noh
    assign {GReadNeeded, GWriteNeeded, GExecNeeded, GInvalidRead, GInvalidWrite, GInvalidExec} = '0;
    assign {GSetDirty, GDAMissing, GOtherFault, GLeafFault, GUpdateDA} = '0;
  end

  // hptw needs to know if there is a Dirty or Access fault occurring on this
  // memory access.  If there is the PTE needs to be updated setting Access
  // and possibly also Dirty.  Dirty is set if the operation is a store/amo.
  // However any other fault should not cause the update, and updates are in software when ENVCFG_ADUE = 0
  assign HPTWUpdateDA = ValidLeafPTE & (~PTE_A | VSSetDirty) & EffADUE & P.SVADU_SUPPORTED & ~(TwoStage ? VSOtherFault : OtherPageFault);
  assign SetDirty = (WalkerState == GLEAF) ? GSetDirty : VSSetDirty;
  assign AccessedPTE = {PTEReg[P.XLEN-1:8], (SetDirty | PTEReg[7]), 1'b1, PTEReg[5:0]}; // set accessed bit, conditionally set dirty bit

  if(P.SVADU_SUPPORTED) begin : hptwwrites
    logic                 SaveHPTWAdr, SelHPTWWriteAdr;
    logic [P.PA_BITS-1:0] HPTWWriteAdr, HPTWWriteAdrSel;
    logic [P.XLEN-1:0]    HPTWWriteData;

    // NextPTE = ReadDataM when ADUE = 0 because UpdatePTE = 0
    assign NextPTE = RestoreVSPTE ? VSPTEReg : UpdatePTE ? AccessedPTE : ReadDataM;
    flopenr #(P.PA_BITS) HPTWAdrWriteReg(clk, reset, SaveHPTWAdr, HPTWReadAdr, HPTWWriteAdr);

    // save the HPTWAdr when the walker is about to read the PTE at any level; the last level read is the one to write during UpdatePTE
    assign SaveHPTWAdr = (NextWalkerState == L0_RD | NextWalkerState == L1_RD | NextWalkerState == L2_RD | NextWalkerState == L3_RD | NextWalkerState == L4_RD |
                          NextWalkerState == G0_RD | NextWalkerState == G1_RD | NextWalkerState == G2_RD | NextWalkerState == G3_RD | NextWalkerState == G4_RD);
    assign SelHPTWWriteAdr = UpdatePTE | HPTWRW[0];
    // A two-stage VS-stage PTE write goes to the supervisor physical address found by the implicit-write G-stage walk
    assign HPTWWriteAdrSel = ((WalkerState == UPDATE_PTE) & TwoStage) ? SPAReg : HPTWWriteAdr;
    mux2 #(P.PA_BITS) HPTWWriteAdrMux(HPTWReadAdr, HPTWWriteAdrSel, SelHPTWWriteAdr, HPTWAdr);

    assign HPTWRW[0] = (WalkerState == UPDATE_PTE) | (WalkerState == GUPDATE_PTE); // HPTWRW[0] will always be 0 if ADUE = 0 because HPTWUpdateDA will be 0 so WalkerState never is UPDATE_PTE
    assign UpdatePTE = ((WalkerState == LEAF) & HPTWUpdateDA) | ((WalkerState == GLEAF) & GUpdateDA);  // UpdatePTE will always be 0 if ADUE = 0 because HPTWUpdateDA will be 0

    // the VS-stage leaf saved in VSPTEReg is what gets written back after the G-stage walk
    assign HPTWWriteData = ((WalkerState == UPDATE_PTE) & TwoStage) ? VSPTEReg : PTEReg;
    mux2 #(P.XLEN) lsuwritedatamux(WriteDataM, HPTWWriteData, SelHPTW, IHWriteDataM);
  end else begin // block: hptwwrites
    assign NextPTE = ReadDataM;
    assign HPTWAdr = HPTWReadAdr;
    assign UpdatePTE = 1'b0;
    assign HPTWRW[0] = 1'b0;
    assign IHWriteDataM = WriteDataM;
  end

  // Enable and select signals based on states
  assign StartWalk  = (WalkerState == IDLE) & TLBMissOrUpdateDA;
  assign HPTWRW[1]  = (WalkerState == L4_RD & P.SV57_SUPPORTED) |
                      (WalkerState == L3_RD & P.SV48_SUPPORTED) |
                      (WalkerState == L2_RD & P.SV39_SUPPORTED) |
                      (WalkerState == L1_RD) | (WalkerState == L0_RD) |
                      (WalkerState == G4_RD & P.SV57_SUPPORTED) |
                      (WalkerState == G3_RD & P.SV48_SUPPORTED) |
                      (WalkerState == G2_RD & P.SV39_SUPPORTED) |
                      (WalkerState == G1_RD) | (WalkerState == G0_RD);
  // Single-stage walks write the TLB from LEAF; two-stage and G-stage-only walks write it
  // once the final G-stage translation succeeds.
  assign GFinalWrite  = (WalkerState == GLEAF) & (GPurpose == GFINAL) & ~GUpdateDA & ~GLeafFault;
  assign TLBWriteCond = ((WalkerState == LEAF) & ~HPTWUpdateDA & ~TwoStage) | GFinalWrite;
  assign DTLBWriteM = TLBWriteCond & DTLBWalk;
  assign ITLBWriteF = TLBWriteCond & ~DTLBWalk;

  // FSM to track PageType based on the levels of the page table traversed
  flopr #(3) PageTypeReg(clk, reset, NextPageType, S1PageType);
  always_comb
    case (WalkerState)
      L4_RD:  NextPageType = 3'b100; // petapage
      L3_RD:  NextPageType = 3'b011; // terapage
      L2_RD:  NextPageType = 3'b010; // gigapage
      L1_RD:  NextPageType = 3'b001; // megapage
      L0_RD:  NextPageType = 3'b000; // kilopage
      default: NextPageType = S1PageType;
    endcase
  flopr #(3) GPageTypeReg(clk, reset, NextGPageType, GPageType);
  always_comb
    case (WalkerState)
      G4_RD:  NextGPageType = 3'b100; // petapage
      G3_RD:  NextGPageType = 3'b011; // terapage
      G2_RD:  NextGPageType = 3'b010; // gigapage
      G1_RD:  NextGPageType = 3'b001; // megapage
      G0_RD:  NextGPageType = 3'b000; // kilopage
      default: NextGPageType = GPageType;
    endcase
  assign MinPageType = (S1PageType < GPageType) ? S1PageType : GPageType;
  // The TLB is written with the merged page size when a G-stage walk completes
  assign PageType = GFinalWrite ? (TwoStage ? MinPageType : GPageType) : S1PageType;

  assign InGWalk = (WalkerState == G0_ADR) | (WalkerState == G0_RD) | (WalkerState == G1_ADR) | (WalkerState == G1_RD) |
                   (WalkerState == G2_ADR) | (WalkerState == G2_RD) | (WalkerState == G3_ADR) | (WalkerState == G3_RD) |
                   (WalkerState == G4_ADR) | (WalkerState == G4_RD) | (WalkerState == GLEAF) | (WalkerState == GUPDATE_PTE);

  // HPTWAdr muxing
  if (P.XLEN==32) begin // RV32
    logic [9:0] VPN;
    logic [P.PPN_BITS-1:0] PPN;
    logic [11:0] GIdx;
    logic [P.PA_BITS-1:0] GReadAdr;
    assign VPN = ((WalkerState == L1_ADR) | (WalkerState == L1_RD)) ? TranslationVAdr[31:22] : TranslationVAdr[21:12]; // select VPN field based on HPTW state
    assign PPN = ((WalkerState == L1_ADR) | (WalkerState == L1_RD)) ? BasePageTablePPN : CurrentPPN;
    assign Stage1ReadAdr = {PPN, VPN, 2'b00};
    assign HPTWSize = 3'b010;
    // Sv32x4: 34-bit GPA, 12-bit top-level index into a 16 KiB root table
    assign GTop = (WalkerState == G1_ADR) | (WalkerState == G1_RD);
    assign GTopADR = (WalkerState == G1_ADR);
    assign GIdx = GTop ? GPAReg[33:22] : {2'b00, GPAReg[21:12]};
    assign GReadAdr = GTop ? {GBasePPN[P.PPN_BITS-1:2], GIdx, 2'b00} : {CurrentPPN, GIdx[9:0], 2'b00};
    assign GInitialWalkerState = G1_ADR;
    assign GPAUpperBitsNonzero = 1'b0; // 34-bit GPA fills GPAReg
    assign HPTWReadAdr = InGWalk ? ((WalkerState == GLEAF) ? SPA : GReadAdr) :
                         TwoStage ? SPAReg : Stage1ReadAdr;
  end else begin // RV64
    logic [8:0] VPN;
    logic [P.PPN_BITS-1:0] PPN;
    logic [10:0] GIdx;
    logic [P.PA_BITS-1:0] GReadAdr;
    always_comb
      case (WalkerState) // select VPN field based on HPTW state
        L4_ADR, L4_RD:  VPN = TranslationVAdr[56:48]; // Extracted top 9 bits for sv57
        L3_ADR, L3_RD:  VPN = TranslationVAdr[47:39];
        L2_ADR, L2_RD:  VPN = TranslationVAdr[38:30];
        L1_ADR, L1_RD:   VPN = TranslationVAdr[29:21];
        default:    VPN = TranslationVAdr[20:12];
      endcase
      assign PPN = ((P.SV57_SUPPORTED & SvMode == P.SV57 & (WalkerState == L4_ADR | WalkerState == L4_RD)) |
                    (P.SV48_SUPPORTED & SvMode == P.SV48 & (WalkerState == L3_ADR | WalkerState == L3_RD)) |
                    (SvMode == P.SV39 & (WalkerState == L2_ADR | WalkerState == L2_RD)) ) ? BasePageTablePPN : CurrentPPN;
    assign Stage1ReadAdr = {PPN, VPN, 3'b000};
    assign HPTWSize = 3'b011;
    // SvXXx4: the top-level index has two extra bits (the root table is 16 KiB and 16 KiB aligned)
    assign GTop = (P.SV57_SUPPORTED & GMode == P.SV57 & (WalkerState == G4_ADR | WalkerState == G4_RD)) |
                  (P.SV48_SUPPORTED & GMode == P.SV48 & (WalkerState == G3_ADR | WalkerState == G3_RD)) |
                  (GMode == P.SV39 & (WalkerState == G2_ADR | WalkerState == G2_RD));
    assign GTopADR = GTop & ((WalkerState == G4_ADR) | (WalkerState == G3_ADR) | (WalkerState == G2_ADR));
    always_comb
      case (WalkerState)
        G4_ADR, G4_RD:  GIdx = GPAReg[58:48];
        G3_ADR, G3_RD:  GIdx = GTop ? GPAReg[49:39] : {2'b00, GPAReg[47:39]};
        G2_ADR, G2_RD:  GIdx = GTop ? GPAReg[40:30] : {2'b00, GPAReg[38:30]};
        G1_ADR, G1_RD:  GIdx = {2'b00, GPAReg[29:21]};
        default:        GIdx = {2'b00, GPAReg[20:12]};
      endcase
    assign GReadAdr = GTop ? {GBasePPN[P.PPN_BITS-1:2], GIdx, 3'b000} : {CurrentPPN, GIdx[8:0], 3'b000};
    assign GInitialWalkerState = (P.SV57_SUPPORTED & GMode == P.SV57) ? G4_ADR :
                                 (P.SV48_SUPPORTED & GMode == P.SV48) ? G3_ADR :
                                                                         G2_ADR;
    // A GPA must fit the G-stage width (41/50/59 bits). With VS-stage Bare the GPA is the
    // virtual address and must also fit the TLB's virtual page number, or it could not be cached.
    assign GPAUpperBitsNonzero = ((P.SV57_SUPPORTED & GMode == P.SV57) ? (|GPAReg[63:59]) :
                                  (P.SV48_SUPPORTED & GMode == P.SV48) ? (|GPAReg[63:50]) :
                                                                          (|GPAReg[63:41])) |
                                 (GOnly & (|GPAReg[63:P.VPN_BITS+12]));
    assign HPTWReadAdr = InGWalk ? ((WalkerState == GLEAF) ? SPA : GReadAdr) :
                         TwoStage ? SPAReg : Stage1ReadAdr;
  end

  // Initial state and misalignment for RV32/64
  if (P.XLEN == 32) begin
    assign InitialWalkerState = L1_ADR;
    assign StartInitialWalkerState = L1_ADR;
    assign MegapageMisaligned = |(CurrentPPN[9:0]); // must have zero PPN0
    assign Misaligned = ((WalkerState == L0_ADR) & MegapageMisaligned);
    assign LeafMisaligned  = (S1PageType == 3'b001) & MegapageMisaligned;
    assign GLeafMisaligned = (GPageType == 3'b001) & MegapageMisaligned;
  end else begin
    logic  PetapageMisaligned, GigapageMisaligned, TerapageMisaligned;
    assign InitialWalkerState = (P.SV57_SUPPORTED & SvMode == P.SV57) ? L4_ADR :
                                (P.SV48_SUPPORTED & SvMode == P.SV48) ? L3_ADR :
                                                                        L2_ADR ;
    assign StartInitialWalkerState = (P.SV57_SUPPORTED & StartSvMode == P.SV57) ? L4_ADR :
                                     (P.SV48_SUPPORTED & StartSvMode == P.SV48) ? L3_ADR :
                                                                                  L2_ADR ;
    assign PetapageMisaligned = P.SV57_SUPPORTED & |(CurrentPPN[35:0]); // Must have zero PPN3, PPN2, PPN1, PPN0
    assign TerapageMisaligned = P.SV48_SUPPORTED & |(CurrentPPN[26:0]); // Must have zero PPN2, PPN1, PPN0
    assign GigapageMisaligned =                    |(CurrentPPN[17:0]); // Must have zero PPN1 and PPN0
    assign MegapageMisaligned = |(CurrentPPN[8:0]);  // Must have zero PPN0
    assign Misaligned = (P.SV57_SUPPORTED & (WalkerState == L3_ADR) & PetapageMisaligned) |
                        (P.SV48_SUPPORTED & (WalkerState == L2_ADR) & TerapageMisaligned) |
                                           ((WalkerState == L1_ADR) & GigapageMisaligned) |
                                           ((WalkerState == L0_ADR) & MegapageMisaligned);
    assign LeafMisaligned  = ((S1PageType == 3'b100) & PetapageMisaligned) | ((S1PageType == 3'b011) & TerapageMisaligned) |
                             ((S1PageType == 3'b010) & GigapageMisaligned) | ((S1PageType == 3'b001) & MegapageMisaligned);
    assign GLeafMisaligned = ((GPageType == 3'b100) & PetapageMisaligned) | ((GPageType == 3'b011) & TerapageMisaligned) |
                             ((GPageType == 3'b010) & GigapageMisaligned) | ((GPageType == 3'b001) & MegapageMisaligned);
  end

  ///////////////////////////////////////////
  // Two-stage address composition
  ///////////////////////////////////////////

  if (P.XLEN == 64) begin: twostage64
    logic [P.PPN_BITS-1:0] FinalGPAPPN;
    logic       MN, MD, MA, MG, MU, MX, MW, MR;
    logic [1:0] MPBMT;
    // Guest physical address from the VS-stage leaf: superpages take their low PPN bits from the virtual address
    always_comb
      case (S1PageType)
        3'b100:  FinalGPAPPN = {CurrentPPN[43:36], TranslationVAdr[47:12]};
        3'b011:  FinalGPAPPN = {CurrentPPN[43:27], TranslationVAdr[38:12]};
        3'b010:  FinalGPAPPN = {CurrentPPN[43:18], TranslationVAdr[29:12]};
        3'b001:  FinalGPAPPN = {CurrentPPN[43:9],  TranslationVAdr[20:12]};
        default: FinalGPAPPN = (P.SVNAPOT_SUPPORTED & PTEReg[63]) ? {CurrentPPN[43:4], TranslationVAdr[15:12]} : CurrentPPN;
      endcase
    assign FinalGPA = {8'b0, FinalGPAPPN, TranslationVAdr[11:0]};
    // Supervisor physical address from the G-stage leaf, mixing in low GPA bits for superpages and NAPOT
    always_comb
      case (GPageType)
        3'b100:  SPAPPN = {CurrentPPN[43:36], GPAReg[47:12]};
        3'b011:  SPAPPN = {CurrentPPN[43:27], GPAReg[38:12]};
        3'b010:  SPAPPN = {CurrentPPN[43:18], GPAReg[29:12]};
        3'b001:  SPAPPN = {CurrentPPN[43:9],  GPAReg[20:12]};
        default: SPAPPN = (P.SVNAPOT_SUPPORTED & PTEReg[63]) ? {CurrentPPN[43:4], GPAReg[15:12]} : CurrentPPN;
      endcase
    assign SPA = {SPAPPN, GPAReg[11:0]};
    // The merged TLB entry uses the smaller page size; the TLB mixer fills in the low PPN bits from the VPN
    always_comb
      case (MinPageType)
        3'b100:  MaskedSPAPPN = {SPAPPN[43:36], 36'b0};
        3'b011:  MaskedSPAPPN = {SPAPPN[43:27], 27'b0};
        3'b010:  MaskedSPAPPN = {SPAPPN[43:18], 18'b0};
        3'b001:  MaskedSPAPPN = {SPAPPN[43:9],  9'b0};
        default: MaskedSPAPPN = SPAPPN;
      endcase
    // Merged entry. G-stage-only walks (VS-stage Bare) cache the G-stage PTE itself, marked
    // global (no VS-stage ASID) and user (the TLB skips the stage-1 privilege check).
    // Two-stage: PBMT from the G-stage unless it is PMA; NAPOT only if the G-stage page covers the region.
    assign MN    = TwoStage ? (VSPTEReg[63] & (GPageType != 3'b000)) : PTEReg[63];
    assign MPBMT = TwoStage ? ((PTEReg[62:61] != 2'b00) ? PTEReg[62:61] : VSPTEReg[62:61]) : PTEReg[62:61];
    assign MD    = TwoStage ? (VSPTEReg[7] & PTEReg[7]) : PTEReg[7];
    assign MA    = TwoStage ? 1'b1 : PTEReg[6];
    assign MG    = TwoStage ? VSPTEReg[5] : 1'b1;
    assign MU    = TwoStage ? VSPTEReg[4] : 1'b1;
    assign MX    = TwoStage ? (VSPTEReg[3] & PTEReg[3]) : PTEReg[3];
    assign MW    = TwoStage ? (VSPTEReg[2] & PTEReg[2]) : PTEReg[2];
    assign MR    = TwoStage ? (VSPTEReg[1] & (PTEReg[1] | (PTEReg[3] & STATUS_MXR))) : PTEReg[1];
    assign MergedPTE = {MN, MPBMT, 7'b0, (TwoStage ? MaskedSPAPPN : CurrentPPN), 2'b00, MD, MA, MG, MU, MX, MW, MR, 1'b1};
  end else begin: twostage32
    logic [P.PPN_BITS-1:0] FinalGPAPPN;
    logic MD, MA, MG, MU, MX, MW, MR;
    assign FinalGPAPPN = (S1PageType == 3'b001) ? {CurrentPPN[21:10], TranslationVAdr[21:12]} : CurrentPPN;
    assign FinalGPA = {FinalGPAPPN, TranslationVAdr[11:0]};
    assign SPAPPN = (GPageType == 3'b001) ? {CurrentPPN[21:10], GPAReg[21:12]} : CurrentPPN;
    assign SPA = {SPAPPN, GPAReg[11:0]};
    assign MaskedSPAPPN = (MinPageType == 3'b001) ? {SPAPPN[21:10], 10'b0} : SPAPPN;
    assign MD    = TwoStage ? (VSPTEReg[7] & PTEReg[7]) : PTEReg[7];
    assign MA    = TwoStage ? 1'b1 : PTEReg[6];
    assign MG    = TwoStage ? VSPTEReg[5] : 1'b1;
    assign MU    = TwoStage ? VSPTEReg[4] : 1'b1;
    assign MX    = TwoStage ? (VSPTEReg[3] & PTEReg[3]) : PTEReg[3];
    assign MW    = TwoStage ? (VSPTEReg[2] & PTEReg[2]) : PTEReg[2];
    assign MR    = TwoStage ? (VSPTEReg[1] & (PTEReg[1] | (PTEReg[3] & STATUS_MXR))) : PTEReg[1];
    assign MergedPTE = {(TwoStage ? MaskedSPAPPN : CurrentPPN), 2'b00, MD, MA, MG, MU, MX, MW, MR, 1'b1};
  end

  // Output to the TLBs: the merged entry when a G-stage walk completes
  assign PTE = GFinalWrite ? MergedPTE : PTEReg;

  ///////////////////////////////////////////
  // G-stage walk bookkeeping registers
  ///////////////////////////////////////////

  // Entering the G-stage walk from IDLE (G-stage only), from an L*_ADR state (implicit read
  // of the VS-stage PTE at that level), or from LEAF (implicit write for A/D, or final translation)
  assign EnterGWalk = P.H_SUPPORTED & (NextWalkerState == GInitialWalkerState) & ~InGWalk;
  always_comb begin
    if (WalkerState == IDLE) begin
      NextGPA = GPA_BITS'(StartTranslationVAdr);
      NextGPurpose = GFINAL;
    end else if (WalkerState == LEAF) begin
      NextGPA = HPTWUpdateDA ? VSPTEGPAReg : FinalGPA;
      NextGPurpose = HPTWUpdateDA ? GIMPLICIT_WR : GFINAL;
    end else begin
      NextGPA = GPA_BITS'(Stage1ReadAdr);
      NextGPurpose = GIMPLICIT_RD;
    end
  end
  always_comb
    case (WalkerState)
      L4_ADR:  ReturnStateVal = L4_RD;
      L3_ADR:  ReturnStateVal = L3_RD;
      L2_ADR:  ReturnStateVal = L2_RD;
      L1_ADR:  ReturnStateVal = L1_RD;
      default: ReturnStateVal = L0_RD;
    endcase
  flopenr #(GPA_BITS) GPARegReg(clk, reset, EnterGWalk, NextGPA, GPAReg);
  flopenr #(GPA_BITS) VSPTEGPARegReg(clk, reset, EnterGWalk & (WalkerState != IDLE) & (WalkerState != LEAF), GPA_BITS'(Stage1ReadAdr), VSPTEGPAReg);
  flopenr #(2)        GPurposeReg(clk, reset, EnterGWalk, NextGPurpose, GPurpose);
  flopenl #(.TYPE(statetype)) ReturnStateReg(clk, reset, EnterGWalk & (WalkerState != IDLE) & (WalkerState != LEAF), ReturnStateVal, L0_RD, ReturnState);
  flopenr #(P.XLEN)   VSPTERegReg(clk, reset, EnterGWalk & (WalkerState == LEAF), HPTWUpdateDA ? AccessedPTE : PTEReg, VSPTEReg);
  flopenr #(P.PA_BITS) SPARegReg(clk, reset, (WalkerState == GLEAF) & ~GLeafFault & ~GUpdateDA, SPA, SPAReg);

  // Page Table Walker FSM
  flopenl #(.TYPE(statetype)) WalkerStateReg(clk, reset | FlushW, 1'b1, NextWalkerState, IDLE, WalkerState);
  always_comb
    case (WalkerState)
      IDLE:       if (TLBMissOrUpdateDA)                              NextWalkerState = StartGOnly ? GInitialWalkerState : StartInitialWalkerState;
                  else                                                NextWalkerState = IDLE;
      L4_ADR:                                                         NextWalkerState = TwoStage ? GInitialWalkerState : L4_RD; // First access in SV57
      L4_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = L4_RD;
                  else                                                NextWalkerState = L3_ADR;   // Transition to level 3
      L3_ADR:     if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (InitialWalkerState == L3_ADR | ValidNonLeafPTE) NextWalkerState = TwoStage ? GInitialWalkerState : L3_RD; // First access in SV48
                  else                                                NextWalkerState = LEAF;
      L3_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = L3_RD;
                  else                                                NextWalkerState = L2_ADR;
      L2_ADR:     if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (InitialWalkerState == L2_ADR | ValidNonLeafPTE) NextWalkerState = TwoStage ? GInitialWalkerState : L2_RD; // First access in SV39
                  else                                                NextWalkerState = LEAF;
      L2_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = L2_RD;
                  else                                                NextWalkerState = L1_ADR;
      L1_ADR:     if  (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (InitialWalkerState == L1_ADR | ValidNonLeafPTE) NextWalkerState = TwoStage ? GInitialWalkerState : L1_RD; // First access in SV32
                  else                                                NextWalkerState = LEAF;
      L1_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = L1_RD;
                  else                                                NextWalkerState = L0_ADR;
      L0_ADR:     if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (ValidNonLeafPTE)                           NextWalkerState = TwoStage ? GInitialWalkerState : L0_RD;
                  else                                                NextWalkerState = LEAF;
      L0_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = L0_RD;
                  else                                                NextWalkerState = LEAF;
      LEAF:       if (TwoStage & VSLeafFault)                         NextWalkerState = FAULT;      // VS-stage faults precede the final G-stage translation
                  else if (P.SVADU_SUPPORTED & HPTWUpdateDA)          NextWalkerState = TwoStage ? GInitialWalkerState : UPDATE_PTE;
                  else                                                NextWalkerState = TwoStage ? GInitialWalkerState : IDLE;
      UPDATE_PTE: if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = UPDATE_PTE;
                  else                                                NextWalkerState = LEAF;
      // G-stage walk
      G4_ADR:     if (GPAUpperBitsNonzero)                            NextWalkerState = FAULT;
                  else                                                NextWalkerState = G4_RD;  // First access in SV57x4
      G4_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = G4_RD;
                  else                                                NextWalkerState = G3_ADR;
      G3_ADR:     if (HPTWFaultM | (GTopADR & GPAUpperBitsNonzero))   NextWalkerState = FAULT;
                  else if (GInitialWalkerState == G3_ADR | ValidNonLeafPTE) NextWalkerState = G3_RD; // First access in SV48x4
                  else                                                NextWalkerState = GLEAF;
      G3_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = G3_RD;
                  else                                                NextWalkerState = G2_ADR;
      G2_ADR:     if (HPTWFaultM | (GTopADR & GPAUpperBitsNonzero))   NextWalkerState = FAULT;
                  else if (GInitialWalkerState == G2_ADR | ValidNonLeafPTE) NextWalkerState = G2_RD; // First access in SV39x4
                  else                                                NextWalkerState = GLEAF;
      G2_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = G2_RD;
                  else                                                NextWalkerState = G1_ADR;
      G1_ADR:     if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (GInitialWalkerState == G1_ADR | ValidNonLeafPTE) NextWalkerState = G1_RD; // First access in SV32x4
                  else                                                NextWalkerState = GLEAF;
      G1_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = G1_RD;
                  else                                                NextWalkerState = G0_ADR;
      G0_ADR:     if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (ValidNonLeafPTE)                           NextWalkerState = G0_RD;
                  else                                                NextWalkerState = GLEAF;
      G0_RD:      if (HPTWFaultM)                                     NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = G0_RD;
                  else                                                NextWalkerState = GLEAF;
      GLEAF:      if (GLeafFault)                                     NextWalkerState = FAULT;
                  else if (P.SVADU_SUPPORTED & GUpdateDA)             NextWalkerState = GUPDATE_PTE;
                  else if (GPurpose == GIMPLICIT_RD)                  NextWalkerState = ReturnState;   // read the VS-stage PTE at SPAReg
                  else if (GPurpose == GIMPLICIT_WR)                  NextWalkerState = UPDATE_PTE;    // write the VS-stage PTE at SPAReg
                  else                                                NextWalkerState = IDLE;          // final translation: TLB written this cycle
      GUPDATE_PTE: if (HPTWFaultM)                                    NextWalkerState = FAULT;
                  else if (DCacheBusStallM)                           NextWalkerState = GUPDATE_PTE;
                  else                                                NextWalkerState = GLEAF;
      FAULT:                                                          NextWalkerState = IDLE;
      default:                                                        NextWalkerState = IDLE; // Should never be reached
    endcase // case (WalkerState)

  assign HPTWFlushW = (WalkerState == IDLE & TLBMissOrUpdateDA) | (WalkerState != IDLE & (HPTWFaultM | GuestFaultM | VSLeafFaultM));

  assign SelHPTW = WalkerState != IDLE;
  assign HPTWStall = (WalkerState != IDLE & WalkerState != FAULT) | (WalkerState == IDLE & TLBMissOrUpdateDA);

  // HTPW address/data/control muxing

  // Once the walk is done and it is time to update the TLB we need to switch back
  // to the original data virtual address.
  assign SelHPTWAdr = SelHPTW & ~(DTLBWriteM | ITLBWriteF);

  // multiplex the outputs to LSU
  if (P.XLEN == 64) assign HPTWAdrExt = {{(P.XLEN+2-P.PA_BITS){1'b0}}, HPTWAdr}; // Extend to 66 bits
  else              assign HPTWAdrExt = HPTWAdr;
  mux2 #(2) rwmux(MemRWM, HPTWRW, SelHPTW, PreLSURWM);
  mux2 #(3) sizemux(Funct3M, HPTWSize, SelHPTW, LSUFunct3M);
  mux2 #(7) funct7mux(Funct7M, 7'b0, SelHPTW, LSUFunct7M);
  mux2 #(2) atomicmux(AtomicM, 2'b00, SelHPTW, LSUAtomicM);
  mux2 #(4) cmomux(CMOpM, 4'b0, SelHPTW, LSUCMOpM);
  mux2 #(P.XLEN+2) lsupadrmux(IEUAdrExtM, HPTWAdrExt, SelHPTWAdr, IHAdrM);

endmodule
