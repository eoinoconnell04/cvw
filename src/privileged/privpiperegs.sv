///////////////////////////////////////////
// privpiperegs.sv
//
// Written: David_Harris@hmc.edu 12 May 2022
// Modified:
//
// Purpose: Pipeline registers for early exceptions
//
// Documentation: RISC-V System on Chip Design
//
// A component of the CORE-V-WALLY configurable RISC-V project.
// https://github.com/openhwgroup/cvw
//
// Copyright (C) 2021-23 Harvey Mudd College & Oklahoma State University
//
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
//
// Licensed under the Solderpad Hardware License v 2.1 (the “License”); you may not use this file
// except in compliance with the License, or, at your option, the Apache License version 2.0. You
// may obtain a copy of the License at
//
// https://solderpad.org/licenses/SHL-2.1/
//
// Unless required by applicable law or agreed to in writing, any work distributed under the
// License is distributed on an “AS IS” BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
// either express or implied. See the License for the specific language governing permissions
// and limitations under the License.
////////////////////////////////////////////////////////////////////////////////////////////////

module privpiperegs #(parameter XLEN = 64, parameter H_SUPPORTED = 0) (
  input  logic            clk, reset,
  input  logic            StallD, StallE, StallM,
  input  logic            FlushD, FlushE, FlushM,
  input  logic            InstrPageFaultF, InstrAccessFaultF,  // instruction faults
  input  logic            HPTWInstrAccessFaultF,               // hptw fault during instruction page fetch
  input  logic            HPTWInstrPageFaultF,                 // hptw fault during instruction page fetch
  input  logic            IllegalIEUFPUInstrD,                 // illegal IEU instruction decoded
  input  logic            HPTWInstrGuestPageFaultF,            // hptw G-stage fault during instruction fetch (hypervisor)
  input  logic [XLEN-1:0] HPTWGPAF,                            // guest physical address >> 2 of that fault
  output logic            InstrPageFaultM, InstrAccessFaultM,  // delayed instruction faults
  output logic            IllegalIEUFPUInstrM,                 // delayed illegal IEU instruction
  output logic            HPTWInstrAccessFaultM,               // hptw fault during instruction page fetch
  output logic            HPTWInstrPageFaultM,                 // hptw fault during instruction page fetch
  output logic            HPTWInstrGuestPageFaultM,            // delayed hptw G-stage instruction fault
  output logic [XLEN-1:0] HPTWInstrGPAM                        // delayed guest physical address >> 2
);

  // Delayed fault signals
  logic                InstrPageFaultD, InstrAccessFaultD, HPTWInstrAccessFaultD, HPTWInstrPageFaultD;
  logic                InstrPageFaultE, InstrAccessFaultE, HPTWInstrAccessFaultE, HPTWInstrPageFaultE;
  logic                IllegalIEUFPUInstrE;

  // pipeline fault signals
  flopenrc #(4) faultregD(clk, reset, FlushD, ~StallD,
                  {InstrPageFaultF, InstrAccessFaultF, HPTWInstrAccessFaultF, HPTWInstrPageFaultF},
                  {InstrPageFaultD, InstrAccessFaultD, HPTWInstrAccessFaultD, HPTWInstrPageFaultD});
  flopenrc #(5) faultregE(clk, reset, FlushE, ~StallE,
                  {IllegalIEUFPUInstrD, InstrPageFaultD, InstrAccessFaultD, HPTWInstrAccessFaultD, HPTWInstrPageFaultD},
                  {IllegalIEUFPUInstrE, InstrPageFaultE, InstrAccessFaultE, HPTWInstrAccessFaultE, HPTWInstrPageFaultE});
  flopenrc #(5) faultregM(clk, reset, FlushM, ~StallM,
                  {IllegalIEUFPUInstrE, InstrPageFaultE, InstrAccessFaultE, HPTWInstrAccessFaultE, HPTWInstrPageFaultE},
                  {IllegalIEUFPUInstrM, InstrPageFaultM, InstrAccessFaultM, HPTWInstrAccessFaultM, HPTWInstrPageFaultM});

  // Guest-page faults on instruction fetch carry their guest physical address with them, because
  // a later fetch may start another walk (and fault again) before this instruction reaches the
  // Memory stage where the trap is taken and htval/mtval2 are written.
  if (H_SUPPORTED) begin: gpf
    logic            HPTWInstrGuestPageFaultD, HPTWInstrGuestPageFaultE;
    logic [XLEN-1:0] HPTWInstrGPAD, HPTWInstrGPAE;
    flopenrc #(1+XLEN) gpfregD(clk, reset, FlushD, ~StallD, {HPTWInstrGuestPageFaultF, HPTWGPAF},      {HPTWInstrGuestPageFaultD, HPTWInstrGPAD});
    flopenrc #(1+XLEN) gpfregE(clk, reset, FlushE, ~StallE, {HPTWInstrGuestPageFaultD, HPTWInstrGPAD}, {HPTWInstrGuestPageFaultE, HPTWInstrGPAE});
    flopenrc #(1+XLEN) gpfregM(clk, reset, FlushM, ~StallM, {HPTWInstrGuestPageFaultE, HPTWInstrGPAE}, {HPTWInstrGuestPageFaultM, HPTWInstrGPAM});
  end else begin: nogpf
    assign HPTWInstrGuestPageFaultM = 1'b0;
    assign HPTWInstrGPAM = '0;
  end
endmodule
