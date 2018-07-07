////////////////////////////////////////////////////////////////////////////////
//
// Filename:	zipcpu.v
//
// Project:	Zip CPU -- a small, lightweight, RISC CPU soft core
//{{{
// Purpose:	This is the top level module holding the core of the Zip CPU
//		together.  The Zip CPU is designed to be as simple as possible.
//	(actual implementation aside ...)  The instruction set is about as
//	RISC as you can get, with only 26 instruction types currently supported.
//	(There are still 8-instruction Op-Codes reserved for floating point,
//	and 5 which can be used for transactions not requiring registers.)
//	Please see the accompanying spec.pdf file for a description of these
//	instructions.
//
//	All instructions are 32-bits wide.  All bus accesses, both address and
//	data, are 32-bits over a wishbone bus.
//
//	The Zip CPU is fully pipelined with the following pipeline stages:
//
//		1. Prefetch, returns the instruction from memory.
//
//		2. Instruction Decode
//
//		3. Read Operands
//
//		4. Apply Instruction
//
//		4. Write-back Results
//
//	Further information about the inner workings of this CPU, such as
//	what causes pipeline stalls, may be found in the spec.pdf file.  (The
//	documentation within this file had become out of date and out of sync
//	with the spec.pdf, so look to the spec.pdf for accurate and up to date
//	information.)
//
//
//	In general, the pipelining is controlled by three pieces of logic
//	per stage: _ce, _stall, and _valid.  _valid means that the stage
//	holds a valid instruction.  _ce means that the instruction from the
//	previous stage is to move into this one, and _stall means that the
//	instruction from the previous stage may not move into this one.
//	The difference between these control signals allows individual stages
//	to propagate instructions independently.  In general, the logic works
//	as:
//
//
//	assign	(n)_ce = (n-1)_valid && (!(n)_stall)
//
//
//	always @(posedge i_clk)
//		if ((i_reset)||(clear_pipeline))
//			(n)_valid = 0
//		else if (n)_ce
//			(n)_valid = 1
//		else if (n+1)_ce
//			(n)_valid = 0
//
//	assign (n)_stall = (  (n-1)_valid && ( pipeline hazard detection )  )
//			|| (  (n)_valid && (n+1)_stall );
//
//	and ...
//
//	always @(posedge i_clk)
//		if (n)_ce
//			(n)_variable = ... whatever logic for this stage
//
//	Note that a stage can stall even if no instruction is loaded into
//	it.
//
//}}}
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015-2018, Gisselquist Technology, LLC
//{{{
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//}}}
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
`define	CPU_SUB_OP	4'h0 // also a compare instruction
`define	CPU_AND_OP	4'h1 // also a test instruction
`define	CPU_BREV_OP	4'h8
`define	CPU_MOV_OP	4'hd
//
`define	CPU_CC_REG	4'he
`define	CPU_PC_REG	4'hf
`define	CPU_CLRCACHE_BIT 14	// Set to clear the I-cache, automatically clears
`define	CPU_PHASE_BIT	13	// Set if we are executing the latter half of a CIS
`define	CPU_FPUERR_BIT	12	// Floating point error flag, set on error
`define	CPU_DIVERR_BIT	11	// Divide error flag, set on divide by zero
`define	CPU_BUSERR_BIT	10	// Bus error flag, set on error
`define	CPU_TRAP_BIT	9	// User TRAP has taken place
`define	CPU_ILL_BIT	8	// Illegal instruction
`define	CPU_BREAK_BIT	7
`define	CPU_STEP_BIT	6	// Will step one (or two CIS) instructions
`define	CPU_GIE_BIT	5
`define	CPU_SLEEP_BIT	4
// Compile time defines
//
`include "cpudefs.v"
//
//
module	zipcpu(i_clk, i_reset, i_interrupt,
		// Debug interface
		i_halt, i_clear_pf_cache, i_dbg_reg, i_dbg_we, i_dbg_data,
			o_dbg_stall, o_dbg_reg, o_dbg_cc,
			o_break,
		// CPU interface to the wishbone bus
		o_wb_gbl_cyc, o_wb_gbl_stb,
			o_wb_lcl_cyc, o_wb_lcl_stb,
			o_wb_we, o_wb_addr, o_wb_data, o_wb_sel,
			i_wb_ack, i_wb_stall, i_wb_data,
			i_wb_err,
		// Accounting/CPU usage interface
		o_op_stall, o_pf_stall, o_i_count
`ifdef	DEBUG_SCOPE
		, o_debug
`endif
		);
	// Parameters
	//{{{
	parameter [31:0] RESET_ADDRESS=32'h0100000;
	parameter	ADDRESS_WIDTH=30,
			LGICACHE=8;
`ifdef	OPT_MULTIPLY
	parameter	IMPLEMENT_MPY = `OPT_MULTIPLY;
`else
	parameter	IMPLEMENT_MPY = 0;
`endif
`ifdef	OPT_DIVIDE
	parameter [0:0]	IMPLEMENT_DIVIDE = 1;
`else
	parameter [0:0]	IMPLEMENT_DIVIDE = 0;
`endif
`ifdef	OPT_IMPLEMENT_FPU
	parameter [0:0]	IMPLEMENT_FPU = 1;
`else
	parameter [0:0]	IMPLEMENT_FPU = 0;
`endif
`ifdef	OPT_EARLY_BRANCHING
	parameter [0:0]	EARLY_BRANCHING = 1;
`else
	parameter [0:0]	EARLY_BRANCHING = 0;
`endif
`ifdef	OPT_CIS
	parameter [0:0]	OPT_CIS = 1'b1;
`else
	parameter [0:0]	OPT_CIS = 1'b0;
`endif
`ifdef	OPT_NO_USERMODE
	localparam	[0:0]	OPT_NO_USERMODE = 1'b1;
`else
	localparam	[0:0]	OPT_NO_USERMODE = 1'b0;
`endif
`ifdef	OPT_PIPELINED
	parameter	[0:0]	OPT_PIPELINED = 1'b1;
`else
	parameter	[0:0]	OPT_PIPELINED = 1'b0;
`endif
`ifdef	OPT_PIPELINED_BUS_ACCESS
	localparam	[0:0]	OPT_PIPELINED_BUS_ACCESS = (OPT_PIPELINED);
`else
	localparam	[0:0]	OPT_PIPELINED_BUS_ACCESS = 1'b0;
`endif
	parameter	[0:0]	IMPLEMENT_LOCK=1;
	localparam	[0:0]	OPT_LOCK=(IMPLEMENT_LOCK)&&(OPT_PIPELINED);
`ifdef	OPT_DCACHE
	parameter		OPT_LGDCACHE = 10;
`else
	parameter		OPT_LGDCACHE = 0;
`endif

	parameter [0:0]	WITH_LOCAL_BUS = 1'b1;
	localparam	AW=ADDRESS_WIDTH;
	localparam	[(AW-1):0]	RESET_BUS_ADDRESS = RESET_ADDRESS[(AW+1):2];
	parameter	F_LGDEPTH=8;

	//}}}
	// I/O declarations
	//{{{
	input	wire		i_clk, i_reset, i_interrupt;
	// Debug interface -- inputs
	input	wire		i_halt, i_clear_pf_cache;
	input	wire	[4:0]	i_dbg_reg;
	input	wire		i_dbg_we;
	input	wire	[31:0]	i_dbg_data;
	// Debug interface -- outputs
	output	wire		o_dbg_stall;
	output	reg	[31:0]	o_dbg_reg;
	output	reg	[3:0]	o_dbg_cc;
	output	wire		o_break;
	// Wishbone interface -- outputs
	output	wire		o_wb_gbl_cyc, o_wb_gbl_stb;
	output	wire		o_wb_lcl_cyc, o_wb_lcl_stb, o_wb_we;
	output	wire	[(AW-1):0]	o_wb_addr;
	output	wire	[31:0]	o_wb_data;
	output	wire	[3:0]	o_wb_sel;
	// Wishbone interface -- inputs
	input	wire		i_wb_ack, i_wb_stall;
	input	wire	[31:0]	i_wb_data;
	input	wire		i_wb_err;
	// Accounting outputs ... to help us count stalls and usage
	output	wire		o_op_stall;
	output	wire		o_pf_stall;
	output	wire		o_i_count;
	//
`ifdef	DEBUG_SCOPE
	output	reg	[31:0]	o_debug;
`endif
	//}}}


	// Registers
	//
	//	The distributed RAM style comment is necessary on the
	// SPARTAN6 with XST to prevent XST from oversimplifying the register
	// set and in the process ruining everything else.  It basically
	// optimizes logic away, to where it no longer works.  The logic
	// as described herein will work, this just makes sure XST implements
	// that logic.
	//
	(* ram_style = "distributed" *)
	reg	[31:0]	regset	[0:(OPT_NO_USERMODE)? 15:31];

	// Condition codes
	// (BUS, TRAP,ILL,BREAKEN,STEP,GIE,SLEEP ), V, N, C, Z
	reg	[3:0]	flags, iflags;
	wire	[14:0]	w_uflags, w_iflags;
	reg		break_en, step, sleep, r_halted;
	wire		break_pending, trap, gie, ubreak, pending_interrupt;
	wire		w_clear_icache, ill_err_u;
	reg		ill_err_i;
	reg		ibus_err_flag;
	wire		ubus_err_flag;
	wire		idiv_err_flag, udiv_err_flag;
	wire		ifpu_err_flag, ufpu_err_flag;
	wire		ihalt_phase, uhalt_phase;

	// The master chip enable
	wire		master_ce, master_stall;

	//
	//
	//	PIPELINE STAGE #1 :: Prefetch
	//		Variable declarations
	//
	//{{{
	reg	[(AW+1):0]	pf_pc;
	wire	[(AW+1):0]	pf_request_address, pf_instruction_pc;
	reg	new_pc;
	wire	clear_pipeline;

	reg			dcd_stalled;
	wire			pf_cyc, pf_stb, pf_we, pf_ack, pf_stall, pf_err;
	wire	[(AW-1):0]	pf_addr;
	wire	[31:0]		pf_data;
	wire	[31:0]		pf_instruction;
	wire			pf_valid, pf_gie, pf_illegal;
	wire			pf_stalled;
	wire			pf_new_pc;
`ifdef	FORMAL
	wire	[31:0]		f_dcd_hidden_state;
`endif

	assign	clear_pipeline = new_pc;
	//}}}

	//
	//
	//	PIPELINE STAGE #2 :: Instruction Decode
	//		Variable declarations
	//
	//
	//{{{
	reg		op_valid /* verilator public_flat */,
			op_valid_mem, op_valid_alu;
	reg		op_valid_div, op_valid_fpu;
	wire		op_stall, dcd_ce, dcd_phase;
	wire	[3:0]	dcd_opn;
	wire	[4:0]	dcd_A, dcd_B, dcd_R, dcd_preA, dcd_preB;
	wire		dcd_Acc, dcd_Bcc, dcd_Apc, dcd_Bpc, dcd_Rcc, dcd_Rpc;
	wire	[3:0]	dcd_F;
	wire		dcd_wR, dcd_rA, dcd_rB,
				dcd_ALU, dcd_M, dcd_DIV, dcd_FP,
				dcd_wF, dcd_gie, dcd_break, dcd_lock,
				dcd_pipe, dcd_ljmp;
	wire		dcd_valid;
	wire	[AW+1:0]	dcd_pc /* verilator public_flat */;
	wire	[31:0]	dcd_I;
	wire		dcd_zI;	// true if dcd_I == 0
	wire	dcd_A_stall, dcd_B_stall, dcd_F_stall;

	wire	dcd_illegal;
	wire			dcd_early_branch, dcd_early_branch_stb;
	wire	[(AW+1):0]	dcd_branch_pc;

	wire		dcd_sim;
	wire	[22:0]	dcd_sim_immv;
	wire		prelock_stall;
	wire		cc_invalid_for_dcd;
	wire		pending_sreg_write;
	//}}}


	//
	//
	//	PIPELINE STAGE #3 :: Read Operands
	//		Variable declarations
	//
	//
	//
	//{{{
	// Now, let's read our operands
	reg	[4:0]	alu_reg;
	wire	[3:0]	op_opn;
	reg	[4:0]	op_R;
	reg		op_Rcc;
	reg	[4:0]	op_Aid, op_Bid;
	reg		op_rA, op_rB;
	reg	[31:0]	r_op_Av, r_op_Bv;
	reg	[(AW+1):0]	op_pc;
	wire	[31:0]	w_op_Av, w_op_Bv, op_Av, op_Bv;
	reg	[31:0]	w_pcB_v, w_pcA_v;
	reg	[31:0]	w_op_BnI;
	reg		op_wR, op_wF;
	wire		op_gie;
	wire	[3:0]	op_Fl;
	reg	[6:0]	r_op_F;
	wire	[7:0]	op_F;
	wire		op_ce, op_phase, op_pipe;
	reg		r_op_break;
	reg	[3:0]	r_op_opn;
	wire	w_op_valid;
	wire	[8:0]	w_cpu_info;
	// Some pipeline control wires
	reg	op_illegal;
	wire	op_break;
	wire	op_lock;

`ifdef	VERILATOR
	reg		op_sim		/* verilator public_flat */;
	reg	[22:0]	op_sim_immv	/* verilator public_flat */;
`else
	wire	op_sim = 1'b0;
`endif
	//}}}


	//
	//
	//	PIPELINE STAGE #4 :: ALU / Memory
	//		Variable declarations
	//
	//
	//{{{
	wire	[(AW+1):0]	alu_pc;
	reg		r_alu_pc_valid, mem_pc_valid;
	wire		alu_pc_valid;
	wire		alu_phase;
	wire		alu_ce /* verilator public_flat */, alu_stall;
	wire	[31:0]	alu_result;
	wire	[3:0]	alu_flags;
	wire		alu_valid, alu_busy;
	wire		set_cond;
	reg		alu_wR, alu_wF;
	wire		alu_gie, alu_illegal;


	wire			mem_ce, mem_stalled;
	wire			mem_pipe_stalled;
	wire			mem_valid, mem_ack, mem_stall, mem_err, bus_err,
				mem_cyc_gbl, mem_cyc_lcl, mem_stb_gbl, mem_stb_lcl, mem_we;
	wire	[4:0]		mem_wreg;

	wire			mem_busy, mem_rdbusy;
	wire	[(AW-1):0]	mem_addr;
	wire	[31:0]		mem_data, mem_result;
	wire	[3:0]		mem_sel;

	wire		div_ce, div_error, div_busy, div_valid;
	wire	[31:0]	div_result;
	wire	[3:0]	div_flags;

	wire		fpu_ce, fpu_error, fpu_busy, fpu_valid;
	wire	[31:0]	fpu_result;
	wire	[3:0]	fpu_flags;
	reg		adf_ce_unconditional;

	wire		bus_lock;

	reg		dbgv, dbg_clear_pipe;
	reg	[31:0]	dbg_val;

	assign	div_ce = (op_valid_div)&&(adf_ce_unconditional)&&(set_cond);
	assign	fpu_ce = (IMPLEMENT_FPU)&&(op_valid_fpu)&&(adf_ce_unconditional)&&(set_cond);

	//}}}

	//
	//
	//	PIPELINE STAGE #5 :: Write-back
	//		Variable declarations
	//
	//{{{
	wire		wr_reg_ce, wr_flags_ce, wr_write_pc, wr_write_cc,
			wr_write_scc, wr_write_ucc;
	wire	[4:0]	wr_reg_id;
	wire	[31:0]	wr_gpreg_vl, wr_spreg_vl;
	wire		w_switch_to_interrupt, w_release_from_interrupt;
	reg	[(AW+1):0]	ipc;
	wire	[(AW+1):0]	upc;
	reg		last_write_to_cc;
	wire		cc_write_hold;
	reg		r_clear_icache;
	//}}}

`ifdef	FORMAL
	wire	[F_LGDEPTH-1:0]
		f_gbl_arb_nreqs, f_gbl_arb_nacks, f_gbl_arb_outstanding,
		f_lcl_arb_nreqs, f_lcl_arb_nacks, f_lcl_arb_outstanding,
		f_gbl_mem_nreqs, f_gbl_mem_nacks, f_gbl_mem_outstanding,
		f_lcl_mem_nreqs, f_lcl_mem_nacks, f_lcl_mem_outstanding,
		f_gbl_pf_nreqs, f_gbl_pf_nacks, f_gbl_pf_outstanding,
		f_lcl_pf_nreqs, f_lcl_pf_nacks, f_lcl_pf_outstanding,
		f_mem_nreqs, f_mem_nacks, f_mem_outstanding,
		f_pf_nreqs, f_pf_nacks, f_pf_outstanding;
	wire	f_mem_pc;
`endif


	//
	//	MASTER: clock enable.
	//
	assign	master_ce = ((!i_halt)||(alu_phase))
				&&(!cc_write_hold)&&(!o_break)&&(!sleep);


	//
	//	PIPELINE STAGE #1 :: Prefetch
	//		Calculate stall conditions
	//
	//	These are calculated externally, within the prefetch module.
	//

	//
	//	PIPELINE STAGE #2 :: Instruction Decode
	//		Calculate stall conditions

	always @(*)
	if (OPT_PIPELINED)
		dcd_stalled = (dcd_valid)&&(op_stall);
	else
		dcd_stalled = (!master_ce)||(ill_err_i)||(dcd_valid)||(op_valid)
			||(ibus_err_flag)||(idiv_err_flag)
			||(alu_busy)||(div_busy)||(fpu_busy)||(mem_busy);
	//
	//	PIPELINE STAGE #3 :: Read Operands
	//		Calculate stall conditions
	//{{{
	generate if (OPT_PIPELINED)
	begin : GEN_OP_STALL
		reg	r_cc_invalid_for_dcd;
		always @(posedge i_clk)
			r_cc_invalid_for_dcd <= (wr_flags_ce)
				||(wr_reg_ce)&&(wr_reg_id[3:0] == `CPU_CC_REG)
				||(op_valid)&&((op_wF)||((op_wR)&&(op_R[3:0] == `CPU_CC_REG)))
				||((alu_wF)||((alu_wR)&&(alu_reg[3:0] == `CPU_CC_REG)))
				||(mem_busy)||(div_busy)||(fpu_busy);

		assign	cc_invalid_for_dcd = r_cc_invalid_for_dcd;

		reg	r_pending_sreg_write;
		initial	r_pending_sreg_write = 1'b0;
		always @(posedge i_clk)
		if (clear_pipeline)
			r_pending_sreg_write <= 1'b0;
		else if (((adf_ce_unconditional)||(mem_ce))
				&&(set_cond)&&(!op_illegal)
				&&(op_wR)
				&&(op_R[3:1] == 3'h7)
				&&(op_R[4:0] != { gie, 4'hf }))
			r_pending_sreg_write <= 1'b1;
		else if ((!mem_rdbusy)&&(!alu_busy))
			r_pending_sreg_write <= 1'b0;

		assign	pending_sreg_write = r_pending_sreg_write;

		assign	op_stall = (op_valid)&&(
		//{{{
			// Only stall if we're loaded w/validins and the
			// next stage is accepting our instruction
			(!adf_ce_unconditional)&&(!mem_ce)
			)
			||(dcd_valid)&&(
				// Stall if we need to wait for an operand A
				// to be ready to read
				(dcd_A_stall)
				// Likewise for B, also includes logic
				// regarding immediate offset (register must
				// be in register file if we need to add to
				// an immediate)
				||(dcd_B_stall)
				// Or if we need to wait on flags to work on the
				// CC register
				||(dcd_F_stall)
			);
		//}}}
		assign	op_ce = ((dcd_valid)||(dcd_illegal)||(dcd_early_branch))&&(!op_stall);

	end else begin // !OPT_PIPELINED

		assign	op_stall = 1'b0; // (o_break)||(pending_interrupt);
		assign	op_ce = ((dcd_valid)||(dcd_early_branch))&&(!op_stall);
		assign	pending_sreg_write = 1'b0;
		assign	cc_invalid_for_dcd = 1'b0;

		// Verilator lint_off UNUSED
		wire	[1:0]	pipe_unused;
		assign		pipe_unused = { cc_invalid_for_dcd,
					pending_sreg_write };
		// Verilator lint_on UNUSED
	end endgenerate

	// BUT ... op_ce is too complex for many of the data operations.  So
	// let's make their circuit enable code simpler.  In particular, if
	// op_ doesn't need to be preserved, we can change it all we want
	// ... right?  The clear_pipeline code, for example, really only needs
	// to determine whether op_valid is true.
	// assign	op_change_data_ce = (!op_stall);
	//}}}

	//
	//	PIPELINE STAGE #4 :: ALU / Memory
	//		Calculate stall conditions
	//
	//{{{
	// 1. Basic stall is if the previous stage is valid and the next is
	//	busy.
	// 2. Also stall if the prior stage is valid and the master clock enable
	//	is de-selected
	// 3. Stall if someone on the other end is writing the CC register,
	//	since we don't know if it'll put us to sleep or not.
	// 4. Last case: Stall if we would otherwise move a break instruction
	//	through the ALU.  Break instructions are not allowed through
	//	the ALU.
	generate if (OPT_PIPELINED)
	begin : GEN_ALU_STALL
		assign	alu_stall = (((master_stall)||(mem_rdbusy))&&(op_valid_alu)) //Case 1&2
			||(wr_reg_ce)&&(wr_write_cc);
		// assign // alu_ce = (master_ce)&&(op_valid_alu)&&(!alu_stall)
		//	&&(!clear_pipeline)&&(!op_illegal)
		//	&&(!pending_sreg_write)
		//	&&(!alu_sreg_stall);
		assign	alu_ce = (adf_ce_unconditional)&&(op_valid_alu);

		// Verilator lint_off unused
		wire	unused_alu_stall = alu_stall;
		// Verilator lint_on  unused
	end else begin

		assign	alu_stall = (master_stall);
		//assign	alu_ce = (master_ce)&&(op_valid_alu)
		//			&&(!clear_pipeline)
		//			&&(!alu_stall);
		assign	alu_ce = (adf_ce_unconditional)&&(op_valid_alu);

		// Verilator lint_off unused
		wire	unused_alu_stall = alu_stall;
		// Verilator lint_on  unused
	end endgenerate
	//

	//
	// Note: if you change the conditions for mem_ce, you must also change
	// alu_pc_valid.
	//
	assign	mem_ce = (master_ce)&&(op_valid_mem)&&(!mem_stalled)
			&&(!clear_pipeline);

	generate if (OPT_PIPELINED_BUS_ACCESS)
	begin

		assign	mem_stalled = (master_stall)||((op_valid_mem)&&(
				(mem_pipe_stalled)
				||(bus_err)||(div_error)
				||((!op_pipe)&&(mem_busy))
				// Stall waiting for flags to be valid
				// Or waiting for a write to the PC register
				// Or CC register, since that can change the
				//  PC as well
				||((wr_reg_ce)
					&&((wr_write_pc)||(wr_write_cc)))));
	end else if (OPT_PIPELINED)
	begin
		assign	mem_stalled = (master_stall)||((op_valid_mem)&&(
				(bus_err)||(div_error)||(mem_busy)
				// Stall waiting for flags to be valid
				// Or waiting for a write to the PC register
				// Or CC register, since that can change the
				//  PC as well
				||((wr_reg_ce)
					&&((wr_write_pc)||(wr_write_cc)))));
	end else begin

		assign	mem_stalled = (master_stall);

	end endgenerate
	//}}}

	assign	master_stall = (!master_ce)||(!op_valid)||(ill_err_i)
			||(ibus_err_flag)||(idiv_err_flag)||(pending_interrupt)
			||(alu_busy)||(div_busy)||(fpu_busy)||(op_break)
			||((OPT_PIPELINED)&&(
				((OPT_LOCK)&&(prelock_stall))
				||((mem_busy)&&(op_illegal))
				||((mem_busy)&&(op_valid_div))
				||(alu_illegal)||(o_break)));


	// ALU, DIV, or FPU CE ... equivalent to the OR of all three of these
	always @(*)
	if (OPT_PIPELINED)
		adf_ce_unconditional =
			(!master_stall)&&(!op_valid_mem)&&(!mem_rdbusy)
			&&((!mem_busy)||(!op_wR)||(op_R[4:1] != { gie, 3'h7}));
	else
		adf_ce_unconditional = (!master_stall)&&(op_valid)&&(!op_valid_mem);

	//
	//
	//	PIPELINE STAGE #1 :: Prefetch
	//
	//
	//{{{
	assign	pf_stalled = (dcd_stalled)||(dcd_phase);

	assign	pf_new_pc = (new_pc)||((dcd_early_branch_stb)&&(!clear_pipeline));

	assign	pf_request_address = ((dcd_early_branch_stb)&&(!clear_pipeline))
				? dcd_branch_pc:pf_pc;
	assign	pf_gie = gie;
`ifdef	FORMAL
	abs_prefetch	#(ADDRESS_WIDTH)
	//{{{
			pf(i_clk, (i_reset), pf_new_pc, w_clear_icache,
				(!pf_stalled),
				pf_request_address,
				pf_instruction, pf_instruction_pc,
					pf_valid,
				pf_cyc, pf_stb, pf_we, pf_addr, pf_data,
				pf_ack, pf_stall, pf_err, i_wb_data,
					pf_illegal);
		always @(*)
		begin
			f_pf_nreqs = 0;
			f_pf_nacks = 0;
			f_pf_outstanding = 0;
		end
	//}}}
`else
`ifdef	OPT_SINGLE_FETCH
	prefetch	#(ADDRESS_WIDTH)
	//{{{
			pf(i_clk, (i_reset), pf_new_pc, w_clear_icache,
				(!pf_stalled),
				pf_request_address,
				pf_instruction, pf_instruction_pc,
					pf_valid, pf_illegal,
				pf_cyc, pf_stb, pf_we, pf_addr, pf_data,
				pf_ack, pf_stall, pf_err, i_wb_data);
	//}}}
`else
`ifdef	OPT_DOUBLE_FETCH

	dblfetch #(ADDRESS_WIDTH)
	//{{{
		pf(i_clk, i_reset, pf_new_pc, w_clear_icache,
				(!pf_stalled),
				pf_request_address,
				pf_instruction, pf_instruction_pc,
					pf_valid,
				pf_cyc, pf_stb, pf_we, pf_addr, pf_data,
					pf_ack, pf_stall, pf_err, i_wb_data,
				pf_illegal);
	//}}}

`else // Not single fetch and not double fetch

`ifdef	OPT_TRADITIONAL_PFCACHE
	pfcache #(LGICACHE, ADDRESS_WIDTH)
	//{{{
		pf(i_clk, i_reset, pf_new_pc, w_clear_icache,
				// dcd_pc,
				(!pf_stalled),
				pf_request_address,
				pf_instruction, pf_instruction_pc, pf_valid,
				pf_cyc, pf_stb, pf_we, pf_addr, pf_data,
					pf_ack, pf_stall, pf_err, i_wb_data,
				pf_illegal);
	//}}}
`else
	pipefetch	#({RESET_BUS_ADDRESS, 2'b00}, LGICACHE, ADDRESS_WIDTH)
	//{{{
			pf(i_clk, i_reset, pf_new_pc,
					w_clear_icache, (!pf_stalled),
					(new_pc)?pf_pc:dcd_branch_pc,
					pf_instruction, pf_instruction_pc, pf_valid,
				pf_cyc, pf_stb, pf_we, pf_addr, pf_data,
					pf_ack, pf_stall, pf_err, i_wb_data,
				(mem_cyc_lcl)||(mem_cyc_gbl),
				pf_illegal);
	//}}}
`endif	// OPT_TRADITIONAL_CACHE
`endif	// OPT_DOUBLE_FETCH
`endif	// OPT_SINGLE_FETCH
`endif	// FORMAL
	//}}}

	//
	//
	//	PIPELINE STAGE #2 :: Instruction Decode
	//
	//
	//{{{
	assign		dcd_ce =((OPT_PIPELINED)&&(!dcd_valid))||(!dcd_stalled);
	idecode #(.ADDRESS_WIDTH(AW),
		.OPT_MPY((IMPLEMENT_MPY!=0)? 1'b1:1'b0),
		.OPT_PIPELINED(OPT_PIPELINED),
		.OPT_EARLY_BRANCHING(EARLY_BRANCHING),
		.OPT_DIVIDE(IMPLEMENT_DIVIDE),
		.OPT_FPU(IMPLEMENT_FPU),
		.OPT_LOCK(OPT_LOCK),
		.OPT_OPIPE(OPT_PIPELINED_BUS_ACCESS),
`ifdef	VERILATOR
		.OPT_SIM(1'b1),
`else
		.OPT_SIM(1'b0),
`endif
		.OPT_CIS(OPT_CIS))
		instruction_decoder(i_clk,
			(i_reset)||(clear_pipeline)||(w_clear_icache),
			dcd_ce,
			dcd_stalled, pf_instruction, pf_gie,
			pf_instruction_pc, pf_valid, pf_illegal,
			dcd_valid, dcd_phase,
			dcd_illegal, dcd_pc,
			{ dcd_Rcc, dcd_Rpc, dcd_R },
			{ dcd_Acc, dcd_Apc, dcd_A },
			{ dcd_Bcc, dcd_Bpc, dcd_B },
			dcd_preA, dcd_preB,
			dcd_I, dcd_zI, dcd_F, dcd_wF, dcd_opn,
			dcd_ALU, dcd_M, dcd_DIV, dcd_FP, dcd_break, dcd_lock,
			dcd_wR,dcd_rA, dcd_rB,
			dcd_early_branch, dcd_early_branch_stb,
			dcd_branch_pc, dcd_ljmp,
			dcd_pipe,
			dcd_sim, dcd_sim_immv
`ifdef	FORMAL
			, f_dcd_hidden_state
`endif
			);
	assign	dcd_gie = pf_gie;
	//}}}

	//
	//
	//	PIPELINE STAGE #3 :: Read Operands (Registers)
	//
	//
	//{{{
	generate if (OPT_PIPELINED_BUS_ACCESS)
	begin : GEN_OP_PIPE
		reg		r_op_pipe;

		initial	r_op_pipe = 1'b0;
		// To be a pipeable operation, there must be
		//	two valid adjacent instructions
		//	Both must be memory instructions
		//	Both must be writes, or both must be reads
		//	Both operations must be to the same identical address,
		//		or at least a single (one) increment above that
		//		address
		//
		// However ... we need to know this before this clock, hence
		// this is calculated in the instruction decoder.
		always @(posedge i_clk)
		if ((clear_pipeline)||(i_halt))
			r_op_pipe <= 1'b0;
		else if (op_ce)
			r_op_pipe <= (dcd_pipe)&&(op_valid_mem);
		else if ((wr_reg_ce)&&(wr_reg_id == op_Bid[4:0]))
			r_op_pipe <= 1'b0;
		else if (mem_ce) // Clear us any time an op_ is clocked in
			r_op_pipe <= 1'b0;

		assign	op_pipe = r_op_pipe;
	end else begin

		assign	op_pipe = 1'b0;

	end endgenerate

// `define	NO_DISTRIBUTED_RAM
`ifdef	NO_DISTRIBUTED_RAM
	reg	[31:0]	pre_rewrite_value, pre_op_Av, pre_op_Bv;
	reg		pre_rewrite_flag_A, pre_rewrite_flag_B;

	always @(posedge i_clk)
	if (dcd_ce)
	begin
		pre_rewrite_flag_A <= (wr_reg_ce)&&(dcd_preA == wr_reg_id);
		pre_rewrite_flag_B <= (wr_reg_ce)&&(dcd_preB == wr_reg_id);
		pre_rewrite_value  <= wr_gpreg_vl;
	end

	generate if (OPT_NO_USERMODE)
	begin
		always @(posedge i_clk)
		if (dcd_ce)
		begin
			pre_op_Av <= regset[dcd_preA[3:0]];
			pre_op_Bv <= regset[dcd_preB[3:0]];
		end
	end else begin

		always @(posedge i_clk)
		if (dcd_ce)
		begin
			pre_op_Av <= regset[dcd_preA];
			pre_op_Bv <= regset[dcd_preB];
		end

	end endgenerate

	assign	w_op_Av = (pre_rewrite_flag_A) ? pre_rewrite_value : pre_op_Av;
	assign	w_op_Bv = (pre_rewrite_flag_B) ? pre_rewrite_value : pre_op_Bv;
`else
	generate if (OPT_NO_USERMODE)
	begin
		assign	w_op_Av = regset[dcd_A[3:0]];
		assign	w_op_Bv = regset[dcd_B[3:0]];
	end else begin

		assign	w_op_Av = regset[dcd_A];
		assign	w_op_Bv = regset[dcd_B];

	end endgenerate
`endif

	assign	w_cpu_info = {
	//{{{
	1'b1,
	(IMPLEMENT_MPY    >0)? 1'b1:1'b0,
	(IMPLEMENT_DIVIDE >0)? 1'b1:1'b0,
	(IMPLEMENT_FPU    >0)? 1'b1:1'b0,
	OPT_PIPELINED,
`ifdef	OPT_TRADITIONAL_CACHE
	1'b1,
`else
	1'b0,
`endif
	(EARLY_BRANCHING > 0)? 1'b1:1'b0,
	OPT_PIPELINED_BUS_ACCESS,
	OPT_CIS
	};
	//}}}

	always @(*)
	if ((OPT_NO_USERMODE)||(dcd_A[4] == dcd_gie))
		w_pcA_v[(AW+1):0] = { dcd_pc[AW+1:2], 2'b00 };
	else
		w_pcA_v[(AW+1):0] = { upc[(AW+1):2], uhalt_phase, 1'b0 };

	generate
	if (AW < 30)
		always @(*)
			w_pcA_v[31:(AW+2)] = 0;
	endgenerate

	generate if (OPT_PIPELINED)
	begin : OPV
		initial	op_R   = 0;
		initial	op_Aid = 0;
		initial	op_Bid = 0;
		initial	op_rA  = 0;
		initial	op_rB  = 0;
		initial	op_Rcc = 0;
		always @(posedge i_clk)
		if (op_ce)
		begin
			op_R   <= dcd_R;
			op_Aid <= dcd_A;
			op_Bid <= dcd_B;
			op_rA  <= (dcd_rA)&&(!dcd_early_branch)&&(!dcd_illegal);
			op_rB  <= (dcd_rB)&&(!dcd_early_branch)&&(!dcd_illegal);
			op_Rcc <= (dcd_Rcc)&&(dcd_wR)&&(dcd_R[4]==dcd_gie);
		end

	end else begin

		always @(*)
		begin
			op_R   = dcd_R;
			op_Aid = dcd_A;
			op_Bid = dcd_B;
			op_rA  = dcd_rA;
			op_rB  = dcd_rB;
			op_Rcc = (dcd_Rcc)&&(dcd_wR)&&(dcd_R[4]==dcd_gie);
		end

	end endgenerate


	always @(posedge i_clk)
	if ((!OPT_PIPELINED)||(op_ce))
	begin
		if ((OPT_PIPELINED)&&(wr_reg_ce)&&(wr_reg_id == dcd_A))
			r_op_Av <= wr_gpreg_vl;
		else if (dcd_Apc)
			r_op_Av <= w_pcA_v;
		else if (dcd_Acc)
			r_op_Av <= { w_cpu_info, w_op_Av[22:16], 1'b0, (dcd_A[4])?w_uflags:w_iflags };
		else
			r_op_Av <= w_op_Av;
	end else if (OPT_PIPELINED)
	begin
		if ((wr_reg_ce)&&(wr_reg_id == op_Aid)&&(op_rA))
			r_op_Av <= wr_gpreg_vl;
	end

	always @(*)
	if ((OPT_NO_USERMODE)||(dcd_B[4] == dcd_gie))
		w_pcB_v[(AW+1):0] = { dcd_pc[AW+1:2], 2'b00 };
	else
		w_pcB_v[(AW+1):0] = { upc[(AW+1):2], uhalt_phase, 1'b0 };
	generate
	if (AW < 30)
		always @(*)
			w_pcB_v[31:(AW+2)] = 0;
	endgenerate

	always @(*)
	if (!dcd_rB)
		w_op_BnI = 0;
	else if ((OPT_PIPELINED)&&(wr_reg_ce)&&(wr_reg_id == dcd_B))
		w_op_BnI = wr_gpreg_vl;
	else if (dcd_Bcc)
		w_op_BnI = { w_cpu_info, w_op_Bv[22:16], 1'b0,
				(dcd_B[4]) ? w_uflags : w_iflags };
	else
		w_op_BnI = w_op_Bv;

	always @(posedge i_clk)
	if ((!OPT_PIPELINED)||(op_ce))
	begin
		if ((dcd_Bpc)&&(dcd_rB))
			r_op_Bv <= w_pcB_v + { dcd_I[29:0], 2'b00 };
		else
			r_op_Bv <= w_op_BnI + dcd_I;
	end else if ((OPT_PIPELINED)&&(op_rB)
			&&(wr_reg_ce)&&(op_Bid == wr_reg_id))
		r_op_Bv <= wr_gpreg_vl;

	// The logic here has become more complex than it should be, no thanks
	// to Xilinx's Vivado trying to help.  The conditions are supposed to
	// be two sets of four bits: the top bits specify what bits matter, the
	// bottom specify what those top bits must equal.  However, two of
	// conditions check whether bits are on, and those are the only two
	// conditions checking those bits.  Therefore, Vivado complains that
	// these two bits are redundant.  Hence the convoluted expression
	// below, arriving at what we finally want in the (now wire net)
	// op_F.
	always @(posedge i_clk)
	if ((!OPT_PIPELINED)||(op_ce))
		// Cannot do op_change_data_ce here since op_F depends
		// upon being either correct for a valid op, or correct
		// for the last valid op
	begin // Set the flag condition codes, bit order is [3:0]=VNCZ
		case(dcd_F[2:0])
		3'h0:	r_op_F <= 7'h00;	// Always
		3'h1:	r_op_F <= 7'h11;	// Z
		3'h2:	r_op_F <= 7'h44;	// LT
		3'h3:	r_op_F <= 7'h22;	// C
		3'h4:	r_op_F <= 7'h08;	// V
		3'h5:	r_op_F <= 7'h10;	// NE
		3'h6:	r_op_F <= 7'h40;	// GE (!N)
		3'h7:	r_op_F <= 7'h20;	// NC
		endcase
	end // Bit order is { (flags_not_used), VNCZ mask, VNCZ value }
	assign	op_F = { r_op_F[3], r_op_F[6:0] };

	assign	w_op_valid = (!clear_pipeline)&&(dcd_valid)
					&&(!dcd_ljmp)&&(!dcd_early_branch);

	initial	op_valid     = 1'b0;
	initial	op_valid_alu = 1'b0;
	initial	op_valid_mem = 1'b0;
	initial	op_valid_div = 1'b0;
	initial	op_valid_fpu = 1'b0;
	always @(posedge i_clk)
		if ((i_reset)||(clear_pipeline))
		begin
			op_valid     <= 1'b0;
			op_valid_alu <= 1'b0;
			op_valid_mem <= 1'b0;
			op_valid_div <= 1'b0;
			op_valid_fpu <= 1'b0;
		end else if (op_ce)
		begin
			// Do we have a valid instruction?
			//   The decoder may vote to stall one of its
			//   instructions based upon something we currently
			//   have in our queue.  This instruction must then
			//   move forward, and get a stall cycle inserted.
			//   Hence, the test on dcd_stalled here.  If we must
			//   wait until our operands are valid, then we aren't
			//   valid yet until then.
			op_valid     <= (w_op_valid)||(dcd_early_branch);
			op_valid_alu <= (w_op_valid)&&((dcd_ALU)||(dcd_illegal));
			op_valid_mem <= (dcd_M)&&(!dcd_illegal)
					&&(w_op_valid);
			op_valid_div <= (IMPLEMENT_DIVIDE)&&(dcd_DIV)&&(!dcd_illegal)&&(w_op_valid);
			op_valid_fpu <= (IMPLEMENT_FPU)&&(dcd_FP)&&(!dcd_illegal)&&(w_op_valid);
		end else if ((adf_ce_unconditional)||(mem_ce))
		begin
			op_valid     <= 1'b0;
			op_valid_alu <= 1'b0;
			op_valid_mem <= 1'b0;
			op_valid_div <= 1'b0;
			op_valid_fpu <= 1'b0;
		end

	// Here's part of our debug interface.  When we recognize a break
	// instruction, we set the op_break flag.  That'll prevent this
	// instruction from entering the ALU, and cause an interrupt before
	// this instruction.  Thus, returning to this code will cause the
	// break to repeat and continue upon return.  To get out of this
	// condition, replace the break instruction with what it is supposed
	// to be, step through it, and then replace it back.  In this fashion,
	// a debugger can step through code.
	// assign w_op_break = (dcd_break)&&(r_dcd_I[15:0] == 16'h0001);

	initial	r_op_break = 1'b0;
	always @(posedge i_clk)
	if (clear_pipeline)
		r_op_break <= 1'b0;
	else if ((OPT_PIPELINED)&&(op_ce))
		r_op_break <= (dcd_valid)&&(dcd_break)&&(!dcd_illegal);
	else if ((!OPT_PIPELINED)&&(dcd_valid))
		r_op_break <= (dcd_break)&&(!dcd_illegal);
	assign	op_break = r_op_break;

	generate if ((!OPT_PIPELINED)||(!OPT_LOCK))
	begin

		assign op_lock       = 1'b0;

		// Verilator lint_off UNUSED
		wire	dcd_lock_unused;
		assign	dcd_lock_unused = dcd_lock;
		// Verilator lint_on  UNUSED

	end else // if (IMPLEMENT_LOCK != 0)
	begin : OPLOCK
		reg	r_op_lock;

		initial	r_op_lock = 1'b0;
		always @(posedge i_clk)
			if (clear_pipeline)
				r_op_lock <= 1'b0;
			else if (op_ce)
				r_op_lock <= (dcd_valid)&&(dcd_lock)
					&&(!dcd_illegal)&&(!clear_pipeline);
		assign	op_lock = r_op_lock;

	end endgenerate

	initial	op_illegal = 1'b0;
	always @(posedge i_clk)
	if ((i_reset)||(clear_pipeline))
		op_illegal <= 1'b0;
	else if (OPT_PIPELINED)
	begin
		if (op_ce)
			op_illegal <= (dcd_valid)&&(!dcd_ljmp)
				&&(!dcd_early_branch)&&(dcd_illegal);
	end else if (!OPT_PIPELINED)
	begin
		if (dcd_valid)
			op_illegal <= (!dcd_ljmp)&&(!dcd_early_branch)&&(dcd_illegal);
	end

	always @(posedge i_clk)
	if ((!OPT_PIPELINED)||(op_ce))
		op_wF <= (dcd_wF)&&((!dcd_Rcc)||(!dcd_wR))
			&&(!dcd_early_branch);

	generate if ((OPT_PIPELINED)||(EARLY_BRANCHING))
	begin

		always @(posedge i_clk)
		if (op_ce)
			op_wR <= (dcd_wR)&&(!dcd_early_branch);

	end else begin

		always @(*)
			op_wR = (dcd_wR);

	end endgenerate

`ifdef	VERILATOR
`ifdef	SINGLE_FETCH
	always @(*)
	begin
		op_sim      = dcd_sim;
		op_sim_immv = dcd_sim_immv;
	end
`else
	always @(posedge i_clk)
		if (op_ce)
		begin
			op_sim      <= dcd_sim;
			op_sim_immv <= dcd_sim_immv;
		end
`endif
`endif


	generate if ((OPT_PIPELINED)||(EARLY_BRANCHING))
	begin : SET_OP_PC

		always @(posedge i_clk)
		if (op_ce)
			op_pc <= (dcd_early_branch)?dcd_branch_pc:dcd_pc;

	end else begin : SET_OP_PC

		always @(*)
			op_pc = dcd_pc;

	end endgenerate

	generate if (!OPT_PIPELINED)
	begin
		always @(*)
			r_op_opn = dcd_opn;

	end else begin

		always @(posedge i_clk)
		if (op_ce)
		begin
			// Which ALU operation?  Early branches are
			// unimplemented moves
			r_op_opn    <= ((dcd_early_branch)||(dcd_illegal))
					? `CPU_MOV_OP : dcd_opn;
			// opM  <= dcd_M;	// Is this a memory operation?
			// What register will these results be written into?
		end

	end endgenerate

	assign	op_opn = r_op_opn;
	assign	op_gie = gie;

	assign	op_Fl = (op_gie)?(w_uflags[3:0]):(w_iflags[3:0]);

	generate if (OPT_CIS)
	begin : OPT_CIS_OP_PHASE

		reg	r_op_phase;

		initial	r_op_phase = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)||(clear_pipeline))
				r_op_phase <= 1'b0;
			else if (op_ce)
				r_op_phase <= (dcd_phase)&&((!dcd_wR)||(!dcd_Rpc));
		assign	op_phase = r_op_phase;
	end else begin : OPT_NOCIS_OP_PHASE
		assign	op_phase = 1'b0;

		// verilator lint_off UNUSED
		wire	OPT_CIS_dcdRpc;
		assign	OPT_CIS_dcdRpc = dcd_Rpc;
		// verilator lint_on  UNUSED
	end endgenerate

	// This is tricky.  First, the PC and Flags registers aren't kept in
	// register set but in special registers of their own.  So step one
	// is to select the right register.  Step to is to replace that
	// register with the results of an ALU or memory operation, if such
	// results are now available.  Otherwise, we'd need to insert a wait
	// state of some type.
	//
	// The alternative approach would be to define some sort of
	// op_stall wire, which would stall any upstream stage.
	// We'll create a flag here to start our coordination.  Once we
	// define this flag to something other than just plain zero, then
	// the stalls will already be in place.
	generate if (OPT_PIPELINED)
	begin

		assign	op_Av = ((wr_reg_ce)&&(wr_reg_id == op_Aid))
			?  wr_gpreg_vl : r_op_Av;

	end else begin

		assign	op_Av = r_op_Av;

	end endgenerate

	// Stall if we have decoded an instruction that will read register A
	//	AND ... something that may write a register is running
	//	AND (series of conditions here ...)
	//		The operation might set flags, and we wish to read the
	//			CC register
	//		OR ... (No other conditions)
	generate if (OPT_PIPELINED)
	begin

		assign	dcd_A_stall = (dcd_rA) // &&(dcd_valid) is checked for elsewhere
				&&((op_valid)||(mem_rdbusy)
					||(div_busy)||(fpu_busy))
				&&(((op_wF)||(cc_invalid_for_dcd))&&(dcd_Acc))
			||((dcd_rA)&&(dcd_Acc)&&(cc_invalid_for_dcd));
	end else begin

		// There are no pipeline hazards, if we aren't pipelined
		assign	dcd_A_stall = 1'b0;

	end endgenerate

	assign	op_Bv = ((OPT_PIPELINED)&&(wr_reg_ce)
					&&(wr_reg_id == op_Bid)&&(op_rB))
			? wr_gpreg_vl: r_op_Bv;

	generate if (OPT_PIPELINED)
	begin
	// Stall if we have decoded an instruction that will read register B
	//	AND ... something that may write a (unknown) register is running
	//	AND (series of conditions here ...)
	//		The operation might set flags, and we wish to read the
	//			CC register
	//		OR the operation might set register B, and we still need
	//			a clock to add the offset to it
	assign	dcd_B_stall = (dcd_rB) // &&(dcd_valid) is checked for elsewhere
	//{{{
				// If the op stage isn't valid, yet something
				// is running, then it must have been valid.
				// We'll use the last values from that stage
				// (op_wR, op_wF, op_R) in our logic below.
				&&((op_valid)||(mem_rdbusy)
					||(div_busy)||(fpu_busy)||(alu_busy))
				&&(
				// Okay, what happens if the result register
				// from instruction 1 becomes the input for
				// instruction two, *and* there's an immediate
				// offset in instruction two?  In that case, we
				// need an extra clock between the two
				// instructions to calculate the base plus
				// offset.
				//
				// What if instruction 1 (or before) is in a
				// memory pipeline?  We may no longer know what
				// the register was!  We will then need  to
				// blindly wait.  We'll temper this only waiting
				// if we're not piping this new instruction.
				// If we were piping, the pipe logic in the
				// decode circuit has told us that the hazard
				// is clear, so we're okay then.
				//
				((!dcd_zI)&&(
					((op_R == dcd_B)&&(op_wR))
					||((mem_rdbusy)&&(!dcd_pipe))
					||(((alu_busy)||(div_busy))&&(alu_reg == dcd_B))
					||((wr_reg_ce)&&(wr_reg_id[3:1] == 3'h7))
					))
				// Stall following any instruction that will
				// set the flags, if we're going to need the
				// flags (CC) register for op_B.
				||(((op_wF)||(cc_invalid_for_dcd))&&(dcd_Bcc))
				// Stall on any ongoing memory operation that
				// will write to op_B -- captured above
				// ||((mem_busy)&&(!mem_we)&&(mem_last_reg==dcd_B)&&(!dcd_zI))
				)
			||((dcd_rB)&&(dcd_Bcc)&&(cc_invalid_for_dcd));
		//}}}
		assign	dcd_F_stall = ((!dcd_F[3])
		//{{{
					||((dcd_rA)&&(dcd_A[3:1]==3'h7)
						&&(dcd_A[4:0] != { gie, 4'hf}))
					||((dcd_rB)&&(dcd_B[3:1]==3'h7))
						&&(dcd_B[4:0] != { gie, 4'hf}))
					&&(((op_valid)&&(op_wR)
						&&(op_R[3:1]==3'h7)
						&&(op_R[4:0]!={gie, 4'hf}))
						||(pending_sreg_write));
				// &&(dcd_valid) is checked for elsewhere
		//}}}
	end else begin
		// No stalls without pipelining, 'cause how can you have a pipeline
		// hazard without the pipeline?
		assign	dcd_B_stall = 1'b0;
		assign	dcd_F_stall = 1'b0;
	end endgenerate

	//}}}
	//
	//
	//	PIPELINE STAGE #4 :: Apply Instruction
	//
	//
	// ALU
	cpuops	#(IMPLEMENT_MPY) doalu(i_clk, ((i_reset)||(clear_pipeline)),
	//{{{
			alu_ce, op_opn, op_Av, op_Bv,
			alu_result, alu_flags, alu_valid, alu_busy);
	//}}}

	// Divide
	//{{{
	generate if (IMPLEMENT_DIVIDE != 0)
	begin : DIVIDE
`ifdef	FORMAL
`define	DIVIDE_MODULE	abs_div
`else
`define	DIVIDE_MODULE	div
`endif
		`DIVIDE_MODULE thedivide(i_clk, ((i_reset)||(clear_pipeline)),
				div_ce, op_opn[0],
			op_Av, op_Bv, div_busy, div_valid, div_error, div_result,
			div_flags);

	end else begin

		assign	div_error = 1'b0; // Can't be high unless div_valid
		assign	div_busy  = 1'b0;
		assign	div_valid = 1'b0;
		assign	div_result= 32'h00;
		assign	div_flags = 4'h0;

		// Make verilator happy here
		// verilator lint_off UNUSED
		wire	unused_divide;
		assign	unused_divide = div_ce;
		// verilator lint_on  UNUSED
	end endgenerate
	//}}}

	// (Non-existent) FPU
	//{{{
	generate if (IMPLEMENT_FPU != 0)
	begin : FPU
		//
		// sfpu thefpu(i_clk, i_reset, fpu_ce,
		//	op_Av, op_Bv, fpu_busy, fpu_valid, fpu_err, fpu_result,
		//	fpu_flags);
		//
		assign	fpu_error = 1'b0; // Must only be true if fpu_valid
		assign	fpu_busy  = 1'b0;
		assign	fpu_valid = 1'b0;
		assign	fpu_result= 32'h00;
		assign	fpu_flags = 4'h0;
	end else begin
		assign	fpu_error = 1'b0;
		assign	fpu_busy  = 1'b0;
		assign	fpu_valid = 1'b0;
		assign	fpu_result= 32'h00;
		assign	fpu_flags = 4'h0;
	end endgenerate
	//}}}


	assign	set_cond = ((op_F[7:4]&op_Fl[3:0])==op_F[3:0]);
	initial	alu_wF   = 1'b0;
	initial	alu_wR   = 1'b0;
	generate if (OPT_PIPELINED)
	begin
		always @(posedge i_clk)
		if (i_reset)
		begin
			alu_wR   <= 1'b0;
			alu_wF   <= 1'b0;
		end else if (alu_ce)
		begin
			// alu_reg <= op_R;
			alu_wR  <= (op_wR)&&(set_cond)&&(!op_illegal);
			alu_wF  <= (op_wF)&&(set_cond)&&(!op_illegal);
		end else if (!alu_busy) begin
			// These are strobe signals, so clear them if not
			// set for any particular clock
			alu_wR <= (r_halted)&&(i_dbg_we);
			alu_wF <= 1'b0;
		end
	end else begin

		always @(posedge i_clk)
			alu_wR  <= (op_wR)&&(set_cond)&&(!op_illegal);
		always @(posedge i_clk)
			alu_wF  <= (op_wF)&&(set_cond)&&(!op_illegal);

	end endgenerate

	generate if (OPT_CIS)
	begin : GEN_ALU_PHASE

		reg	r_alu_phase;
		initial	r_alu_phase = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)||(clear_pipeline))
				r_alu_phase <= 1'b0;
			else if (((adf_ce_unconditional)||(mem_ce))&&(op_valid))
				r_alu_phase <= op_phase;
			else if ((adf_ce_unconditional)||(mem_ce))
				r_alu_phase <= 1'b0;
		assign	alu_phase = r_alu_phase;
	end else begin

		assign	alu_phase = 1'b0;
	end endgenerate

	generate if (OPT_PIPELINED)
	begin

		always @(posedge i_clk)
		if (adf_ce_unconditional)
			alu_reg <= op_R;
		else if ((r_halted)&&(i_dbg_we))
			alu_reg <= i_dbg_reg;

	end else begin

		always @(posedge i_clk)
			if ((r_halted)&&(i_dbg_we))
				alu_reg <= i_dbg_reg;
			else
				alu_reg <= op_R;
	end endgenerate

	//
	// DEBUG Register write access starts here
	//
	//{{{
	initial	dbgv = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		dbgv <= 0;
	else
		dbgv <= (i_dbg_we)&&(r_halted);

	always @(posedge i_clk)
		dbg_val <= i_dbg_data;
	always @(posedge i_clk)
	if ((i_reset)||(clear_pipeline))
		dbg_clear_pipe <= 0;
	else if ((i_dbg_we)&&(r_halted))
	begin
		if (!OPT_PIPELINED)
			dbg_clear_pipe <= 1'b1;
		else if ((i_dbg_reg == op_Bid)&&(op_rB))
			dbg_clear_pipe <= 1'b1;
		else if (i_dbg_reg[3:1] == 3'h7)
			dbg_clear_pipe <= 1'b1;
		else
			dbg_clear_pipe <= 1'b0;
	end else if ((!OPT_PIPELINED)&&(i_clear_pf_cache))
		dbg_clear_pipe <= 1'b1;
	else
		dbg_clear_pipe <= 1'b0;

	assign	alu_gie = gie;
	//}}}

	generate if (OPT_PIPELINED)
	begin : GEN_ALU_PC
		reg	[(AW+1):0]	r_alu_pc;
		initial	r_alu_pc = 0;
		always @(posedge i_clk)
		if (i_reset)
			r_alu_pc <= 0;
		else if ((adf_ce_unconditional)
				||((master_ce)&&(op_valid_mem)
					&&(!clear_pipeline)&&(!mem_stalled)))
			r_alu_pc  <= op_pc;
		assign	alu_pc = r_alu_pc;

	end else begin

		assign	alu_pc = op_pc;

	end endgenerate

	generate if (OPT_PIPELINED)
	begin : SET_ALU_ILLEGAL
		reg		r_alu_illegal;

		initial	r_alu_illegal = 0;
		always @(posedge i_clk)
			if (clear_pipeline)
				r_alu_illegal <= 1'b0;
			else if (adf_ce_unconditional)
				r_alu_illegal <= op_illegal;
			else
				r_alu_illegal <= 1'b0;

		assign	alu_illegal = (r_alu_illegal);
	end else begin : SET_ALU_ILLEGAL
		assign	alu_illegal = op_illegal;
	end endgenerate

	initial	r_alu_pc_valid = 1'b0;
	initial	mem_pc_valid = 1'b0;
	always @(posedge i_clk)
		if (clear_pipeline)
			r_alu_pc_valid <= 1'b0;
		else if ((adf_ce_unconditional)&&(!op_phase))
			r_alu_pc_valid <= 1'b1;
		else if (((!alu_busy)&&(!div_busy)&&(!fpu_busy))||(clear_pipeline))
			r_alu_pc_valid <= 1'b0;
	assign	alu_pc_valid = (r_alu_pc_valid)&&((!alu_busy)&&(!div_busy)&&(!fpu_busy));
	always @(posedge i_clk)
		if (i_reset)
			mem_pc_valid <= 1'b0;
		else
			mem_pc_valid <= (mem_ce);

	// Bus lock logic
	//{{{
	generate
	if ((OPT_PIPELINED)&&(!OPT_LOCK))
	begin : BUSLOCK
		reg	r_prelock_stall;

		initial	r_prelock_stall = 1'b0;
		always @(posedge i_clk)
			if (clear_pipeline)
				r_prelock_stall <= 1'b0;
			else if ((op_valid)&&(op_lock)&&(op_ce))
				r_prelock_stall <= 1'b1;
			else if ((op_valid)&&(dcd_valid)&&(pf_valid))
				r_prelock_stall <= 1'b0;

		assign	prelock_stall = r_prelock_stall;

		reg	r_prelock_primed;
		initial	r_prelock_primed = 1'b0;
		always @(posedge i_clk)
			if (clear_pipeline)
				r_prelock_primed <= 1'b0;
			else if (r_prelock_stall)
				r_prelock_primed <= 1'b1;
			else if ((adf_ce_unconditional)||(mem_ce))
				r_prelock_primed <= 1'b0;

		reg	[1:0]	r_bus_lock;
		initial	r_bus_lock = 2'b00;
		always @(posedge i_clk)
			if (clear_pipeline)
				r_bus_lock <= 2'b00;
			else if ((op_valid)&&((adf_ce_unconditional)||(mem_ce)))
			begin
				if (r_prelock_primed)
					r_bus_lock <= 2'b10;
				else if (r_bus_lock != 2'h0)
					r_bus_lock <= r_bus_lock + 2'b11;
			end
		assign	bus_lock = |r_bus_lock;
	end else begin
		assign	prelock_stall = 1'b0;
		assign	bus_lock = 1'b0;
	end endgenerate
	//}}}

	// Memory interface
	//{{{
	generate if (OPT_LGDCACHE > 0)
	begin : MEM_DCACHE

		dcache #(.LGCACHELEN(OPT_LGDCACHE), .ADDRESS_WIDTH(AW),
			.LGNLINES(6), .OPT_LOCAL_BUS(WITH_LOCAL_BUS),
			.OPT_PIPE(OPT_PIPELINED_BUS_ACCESS),
			.OPT_LOCK(OPT_LOCK)
`ifdef	FORMAL
			, .F_LGDEPTH(F_LGDEPTH)
`endif
			) docache(i_clk, i_reset,
		///{{{
				(mem_ce)&&(set_cond), bus_lock,
				(op_opn[2:0]), op_Bv, op_Av, op_R,
				mem_busy, mem_pipe_stalled,
				mem_valid, bus_err, mem_wreg, mem_result,
			mem_cyc_gbl, mem_cyc_lcl,
				mem_stb_gbl, mem_stb_lcl,
				mem_we, mem_addr, mem_data, mem_sel,
				mem_ack, mem_stall, mem_err, i_wb_data
`ifdef	FORMAL
			, f_mem_nreqs, f_mem_nacks, f_mem_outstanding, f_mem_pc
`endif
			);
		///}}}
	end else begin : NO_CACHE
	if (OPT_PIPELINED_BUS_ACCESS)
	begin : MEM

		pipemem	#(.ADDRESS_WIDTH(AW),
			.IMPLEMENT_LOCK(OPT_LOCK),
			.WITH_LOCAL_BUS(WITH_LOCAL_BUS)
`ifdef	FORMAL
			, .OPT_MAXDEPTH(4'h3),
			.F_LGDEPTH(F_LGDEPTH)
`endif
			) domem(i_clk,i_reset,
		///{{{
			(mem_ce)&&(set_cond), bus_lock,
				(op_opn[2:0]), op_Bv, op_Av, op_R,
				mem_busy, mem_pipe_stalled,
				mem_valid, bus_err, mem_wreg, mem_result,
			mem_cyc_gbl, mem_cyc_lcl,
				mem_stb_gbl, mem_stb_lcl,
				mem_we, mem_addr, mem_data, mem_sel,
				mem_ack, mem_stall, mem_err, i_wb_data
`ifdef	FORMAL
			, f_mem_nreqs, f_mem_nacks, f_mem_outstanding, f_mem_pc
`endif
			);
		//}}}
	end else begin : MEM

		memops	#(.ADDRESS_WIDTH(AW),
			.IMPLEMENT_LOCK(OPT_LOCK),
			.WITH_LOCAL_BUS(WITH_LOCAL_BUS)
`ifdef	FORMAL
			, .F_LGDEPTH(F_LGDEPTH)
`endif	// F_LGDEPTH
			) domem(i_clk,i_reset,
		//{{{
			(mem_ce)&&(set_cond), bus_lock,
				(op_opn[2:0]), op_Bv, op_Av, op_R,
				mem_busy,
				mem_valid, bus_err, mem_wreg, mem_result,
			mem_cyc_gbl, mem_cyc_lcl,
				mem_stb_gbl, mem_stb_lcl,
				mem_we, mem_addr, mem_data, mem_sel,
				mem_ack, mem_stall, mem_err, i_wb_data
`ifdef	FORMAL
			, f_mem_nreqs, f_mem_nacks, f_mem_outstanding
`endif
			);
`ifdef	FORMAL
		assign	f_mem_pc = 1'b0;
`endif
		//}}}
		assign	mem_pipe_stalled = 1'b0;
	end end endgenerate

	assign	mem_rdbusy = (mem_busy)&&((!OPT_PIPELINED)||(!mem_we));

	// Either the prefetch or the instruction gets the memory bus, but
	// never both.
	wbdblpriarb	#(.DW(32),.AW(AW)
`ifdef	FORMAL
		,.F_LGDEPTH(F_LGDEPTH), .F_MAX_STALL(2), .F_MAX_ACK_DELAY(2)
`endif // FORMAL
		) pformem(i_clk, i_reset,
	//{{{
		// Memory access to the arbiter, priority position
		mem_cyc_gbl, mem_cyc_lcl, mem_stb_gbl, mem_stb_lcl,
			mem_we, mem_addr, mem_data, mem_sel,
			mem_ack, mem_stall, mem_err,
		// Prefetch access to the arbiter
		//
		// At a first glance, we might want something like:
		//
		// pf_cyc, 1'b0, pf_stb, 1'b0, pf_we, pf_addr, pf_data, 4'hf,
		//
		// However, we know that the prefetch will not generate any
		// writes.  Therefore, the write specific lines (mem_data and
		// mem_sel) can be shared with the memory in order to ease
		// timing and LUT usage.
		pf_cyc,1'b0,pf_stb, 1'b0, pf_we, pf_addr, mem_data, mem_sel,
			pf_ack, pf_stall, pf_err,
		// Common wires, in and out, of the arbiter
		o_wb_gbl_cyc, o_wb_lcl_cyc, o_wb_gbl_stb, o_wb_lcl_stb,
			o_wb_we, o_wb_addr, o_wb_data, o_wb_sel,
			i_wb_ack, i_wb_stall, i_wb_err
`ifdef	FORMAL
		,f_gbl_arb_nreqs, f_gbl_arb_nacks, f_gbl_arb_outstanding,
		f_lcl_arb_nreqs, f_lcl_arb_nacks, f_lcl_arb_outstanding,
		f_gbl_mem_nreqs, f_gbl_mem_nacks, f_gbl_mem_outstanding,
		f_lcl_mem_nreqs, f_lcl_mem_nacks, f_lcl_mem_outstanding,
		f_gbl_pf_nreqs, f_gbl_pf_nacks, f_gbl_pf_outstanding,
		f_lcl_pf_nreqs, f_lcl_pf_nacks, f_lcl_pf_outstanding
`endif
		);
	//}}}
	//}}}


	//
	//
	//
	//
	//
	//
	//
	//
	//	PIPELINE STAGE #5 :: Write-back results
	//
	//{{{
	//
	// This stage is not allowed to stall.  If results are ready to be
	// written back, they are written back at all cost.  Sleepy CPU's
	// won't prevent write back, nor debug modes, halting the CPU, nor
	// anything else.  Indeed, the (master_ce) bit is only as relevant
	// as knowinig something is available for writeback.

	//
	// Write back to our generic register set ...
	// When shall we write back?  On one of two conditions
	//	Note that the flags needed to be checked before issuing the
	//	bus instruction, so they don't need to be checked here.
	//	Further, alu_wR includes (set_cond), so we don't need to
	//	check for that here either.
	assign	wr_reg_ce = (dbgv)||(mem_valid)
				||((!clear_pipeline)&&(!alu_illegal)
					&&(((alu_wR)&&(alu_valid))
						||((div_valid)&&(!div_error))
						||((fpu_valid)&&(!fpu_error))));
	// Which register shall be written?
	//	COULD SIMPLIFY THIS: by adding three bits to these registers,
	//		One or PC, one for CC, and one for GIE match
	//	Note that the alu_reg is the register to write on a divide or
	//	FPU operation.
	generate if (OPT_NO_USERMODE)
	begin
		assign	wr_reg_id[3:0] = (alu_wR|div_valid|fpu_valid)
				? alu_reg[3:0]:mem_wreg[3:0];

		assign	wr_reg_id[4] = 1'b0;
	end else begin
		assign	wr_reg_id = (alu_wR|div_valid|fpu_valid)
				? alu_reg : mem_wreg;
	end endgenerate

	// Are we writing to the CC register?
	assign	wr_write_cc = (wr_reg_id[3:0] == `CPU_CC_REG);
	assign	wr_write_scc = (wr_reg_id[4:0] == {1'b0, `CPU_CC_REG});
	assign	wr_write_ucc = (wr_reg_id[4:0] == {1'b1, `CPU_CC_REG});
	// Are we writing to the PC?
	assign	wr_write_pc = (wr_reg_id[3:0] == `CPU_PC_REG);

	// What value to write?
	assign	wr_gpreg_vl = ((mem_valid) ? mem_result
				:((div_valid|fpu_valid))
					? ((div_valid) ? div_result:fpu_result)
				:((dbgv) ? dbg_val : alu_result));
	assign	wr_spreg_vl = ((mem_valid) ? mem_result
				:((dbgv) ? dbg_val : alu_result));

	generate if (OPT_NO_USERMODE)
	begin : SET_REGISTERS

		always @(posedge i_clk)
			if (wr_reg_ce)
				regset[{1'b0,wr_reg_id[3:0]}] <= wr_gpreg_vl;

	end else begin : SET_REGISTERS

		always @(posedge i_clk)
			if (wr_reg_ce)
				regset[wr_reg_id] <= wr_gpreg_vl;

	end endgenerate


	//
	// Write back to the condition codes/flags register ...
	// When shall we write to our flags register?  alu_wF already
	// includes the set condition ...
	assign	wr_flags_ce = (alu_wF)&&((alu_valid)
				||(div_valid)||(fpu_valid))
				&&(!clear_pipeline)&&(!alu_illegal);
	assign	w_uflags = { 1'b0, uhalt_phase, ufpu_err_flag,
			udiv_err_flag, ubus_err_flag, trap, ill_err_u,
			ubreak, step, 1'b1, sleep,
			((wr_flags_ce)&&(alu_gie))?alu_flags:flags };
	assign	w_iflags = { 1'b0, ihalt_phase, ifpu_err_flag,
			idiv_err_flag, ibus_err_flag, trap, ill_err_i,
			break_en, 1'b0, 1'b0, sleep,
			((wr_flags_ce)&&(!alu_gie))?alu_flags:iflags };


	// What value to write?
	always @(posedge i_clk)
		// If explicitly writing the register itself
		if ((wr_reg_ce)&&(wr_write_ucc))
			flags <= wr_gpreg_vl[3:0];
		// Otherwise if we're setting the flags from an ALU operation
		else if ((wr_flags_ce)&&(alu_gie))
			flags <= (div_valid)?div_flags:((fpu_valid)?fpu_flags
				: alu_flags);

	always @(posedge i_clk)
		if ((wr_reg_ce)&&(wr_write_scc))
			iflags <= wr_gpreg_vl[3:0];
		else if ((wr_flags_ce)&&(!alu_gie))
			iflags <= (div_valid)?div_flags:((fpu_valid)?fpu_flags
				: alu_flags);

	// The 'break' enable  bit.  This bit can only be set from supervisor
	// mode.  It control what the CPU does upon encountering a break
	// instruction.
	//
	// The goal, upon encountering a break is that the CPU should stop and
	// not execute the break instruction, choosing instead to enter into
	// either interrupt mode or halt first.
	//	if ((break_en) AND (break_instruction)) // user mode or not
	//		HALT CPU
	//	else if (break_instruction) // only in user mode
	//		set an interrupt flag, set the user break bit,
	//		go to supervisor mode, allow supervisor to step the CPU.
	//	Upon a CPU halt, any break condition will be reset.  The
	//	external debugger will then need to deal with whatever
	//	condition has taken place.
	initial	break_en = 1'b0;
	always @(posedge i_clk)
		if ((i_reset)||(i_halt))
			break_en <= 1'b0;
		else if ((wr_reg_ce)&&(wr_write_scc))
			break_en <= wr_spreg_vl[`CPU_BREAK_BIT];

	generate if (OPT_PIPELINED)
	begin : GEN_PENDING_BREAK
		reg	r_break_pending;

		initial	r_break_pending = 1'b0;
		always @(posedge i_clk)
			if ((clear_pipeline)||(!op_valid))
				r_break_pending <= 1'b0;
			else if ((op_break)&&(!r_break_pending))
				r_break_pending <= (!alu_busy)&&(!div_busy)
					&&(!fpu_busy)&&(!mem_busy)
					&&(!wr_reg_ce);
			// else
				// r_break_pending <= 1'b0;
		assign	break_pending = r_break_pending;
	end else begin

		assign	break_pending = op_break;
	end endgenerate


	assign	o_break = ((break_en)||(!op_gie))&&(break_pending)
				&&(!clear_pipeline)
			||(ill_err_i)
			||((!alu_gie)&&(bus_err))
			||((!alu_gie)&&(div_error))
			||((!alu_gie)&&(fpu_error))
			||((!alu_gie)&&(alu_illegal)&&(!clear_pipeline));

	// The sleep register.  Setting the sleep register causes the CPU to
	// sleep until the next interrupt.  Setting the sleep register within
	// interrupt mode causes the processor to halt until a reset.  This is
	// a panic/fault halt.  The trick is that you cannot be allowed to
	// set the sleep bit and switch to supervisor mode in the same
	// instruction: users are not allowed to halt the CPU.
	initial	sleep = 1'b0;
	generate if (OPT_NO_USERMODE)
	begin : GEN_NO_USERMODE_SLEEP
		reg	r_sleep_is_halt;
		initial	r_sleep_is_halt = 1'b0;
		always @(posedge i_clk)
			if (i_reset)
				r_sleep_is_halt <= 1'b0;
			else if ((wr_reg_ce)&&(wr_write_cc)
					&&(wr_spreg_vl[`CPU_SLEEP_BIT])
					&&(!wr_spreg_vl[`CPU_GIE_BIT]))
				r_sleep_is_halt <= 1'b1;

		// Trying to switch to user mode, either via a WAIT or an RTU
		// instruction will cause the CPU to sleep until an interrupt, in
		// the NO-USERMODE build.
		always @(posedge i_clk)
			if ((i_reset)||((i_interrupt)&&(!r_sleep_is_halt)))
				sleep <= 1'b0;
			else if ((wr_reg_ce)&&(wr_write_cc)
					&&(wr_spreg_vl[`CPU_GIE_BIT]))
				sleep <= 1'b1;
	end else begin : GEN_SLEEP

		always @(posedge i_clk)
			if ((i_reset)||(w_switch_to_interrupt))
				sleep <= 1'b0;
			else if ((wr_reg_ce)&&(wr_write_cc)&&(!alu_gie))
				// In supervisor mode, we have no protections.
				// The supervisor can set the sleep bit however
				// he wants.  Well ... not quite.  Switching to
				// user mode and sleep mode shouold only be
				// possible if the interrupt flag isn't set.
				//	Thus: if (i_interrupt)
				//			&&(wr_spreg_vl[GIE])
				//		don't set the sleep bit
				//	otherwise however it would o.w. be set
				sleep <= (wr_spreg_vl[`CPU_SLEEP_BIT])
					&&((!i_interrupt)
						||(!wr_spreg_vl[`CPU_GIE_BIT]));
			else if ((wr_reg_ce)&&(wr_write_cc)
						&&(wr_spreg_vl[`CPU_GIE_BIT]))
				// In user mode, however, you can only set the
				// sleep mode while remaining in user mode.
				// You can't switch to sleep mode *and*
				// supervisor mode at the same time, lest you
				// halt the CPU.
				sleep <= wr_spreg_vl[`CPU_SLEEP_BIT];
	end endgenerate

	always @(posedge i_clk)
		if (i_reset)
			step <= 1'b0;
		else if ((wr_reg_ce)&&(!alu_gie)&&(wr_write_ucc))
			step <= wr_spreg_vl[`CPU_STEP_BIT];

	// The GIE register.  Only interrupts can disable the interrupt register
	generate if (OPT_NO_USERMODE)
	begin

		assign	w_switch_to_interrupt    = 1'b0;
		assign	w_release_from_interrupt = 1'b0;

	end else begin : GEN_PENDING_INTERRUPT
		reg	r_pending_interrupt;

		always @(posedge i_clk)
		if (i_reset)
			r_pending_interrupt <= 1'b0;
		else if ((clear_pipeline)||(w_switch_to_interrupt)||(!gie))
			r_pending_interrupt <= 1'b0;
		else if (i_interrupt)
			r_pending_interrupt <= 1'b1;
		else if (adf_ce_unconditional)
		begin
			if ((op_illegal)||(step)||(break_pending))
				r_pending_interrupt <= 1'b1;
		end else if (break_pending)
			r_pending_interrupt <= 1'b1;
		else if ((mem_ce)&&(step))
			r_pending_interrupt <= 1'b1;

		assign	pending_interrupt = r_pending_interrupt;


		assign	w_switch_to_interrupt = (gie)&&(
			// On interrupt (obviously)
			((pending_interrupt)
				&&(!alu_phase)&&(!bus_lock)&&(!mem_busy))
			//
			// On division by zero.  If the divide isn't
			// implemented, div_valid and div_error will be short
			// circuited and that logic will be bypassed
			||(div_error)
			//
			// Same thing on a floating point error.  Note that
			// fpu_error must *never* be set unless fpu_valid is
			// also set as well, else this will fail.
			||(fpu_error)
			//
			//
			||(bus_err)
			//
			// If we write to the CC register
			||((wr_reg_ce)&&(!wr_spreg_vl[`CPU_GIE_BIT])
				&&(wr_reg_id[4])&&(wr_write_cc))
			);
	assign	w_release_from_interrupt = (!gie)&&(!i_interrupt)
			// Then if we write the sCC register
			&&(((wr_reg_ce)&&(wr_spreg_vl[`CPU_GIE_BIT])
				&&(wr_write_scc))
			);
	end endgenerate

	generate if (OPT_NO_USERMODE)
	begin
		assign	gie = 1'b0;
	end else begin : SET_GIE

		reg	r_gie;

		initial	r_gie = 1'b0;
		always @(posedge i_clk)
			if (i_reset)
				r_gie <= 1'b0;
			else if (w_switch_to_interrupt)
				r_gie <= 1'b0;
			else if (w_release_from_interrupt)
				r_gie <= 1'b1;
		assign	gie = r_gie;
	end endgenerate

	generate if (OPT_NO_USERMODE)
	begin

		assign	trap   = 1'b0;
		assign	ubreak = 1'b0;

	end else begin : SET_TRAP_N_UBREAK

		reg	r_trap;

		initial	r_trap = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)||(w_release_from_interrupt))
				r_trap <= 1'b0;
			else if ((alu_gie)&&(wr_reg_ce)&&(!wr_spreg_vl[`CPU_GIE_BIT])
					&&(wr_write_ucc)) // &&(wr_reg_id[4]) implied
				r_trap <= 1'b1;
			else if ((wr_reg_ce)&&(wr_write_ucc)&&(!alu_gie))
				r_trap <= (r_trap)&&(wr_spreg_vl[`CPU_TRAP_BIT]);

		reg	r_ubreak;

		initial	r_ubreak = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)||(w_release_from_interrupt))
				r_ubreak <= 1'b0;
			else if ((op_gie)&&(break_pending)&&(w_switch_to_interrupt))
				r_ubreak <= 1'b1;
			else if (((!alu_gie)||(dbgv))&&(wr_reg_ce)&&(wr_write_ucc))
				r_ubreak <= (ubreak)&&(wr_spreg_vl[`CPU_BREAK_BIT]);

		assign	trap = r_trap;
		assign	ubreak = r_ubreak;

	end endgenerate


	initial	ill_err_i = 1'b0;
	always @(posedge i_clk)
		if (i_reset)
			ill_err_i <= 1'b0;
		// Only the debug interface can clear this bit
		else if ((dbgv)&&(wr_write_scc))
			ill_err_i <= (ill_err_i)&&(wr_spreg_vl[`CPU_ILL_BIT]);
		else if ((alu_illegal)&&(!alu_gie)&&(!clear_pipeline))
			ill_err_i <= 1'b1;

	generate if (OPT_NO_USERMODE)
	begin

		assign	ill_err_u = 1'b0;

	end else begin : SET_USER_ILLEGAL_INSN

		reg	r_ill_err_u;

		initial	r_ill_err_u = 1'b0;
		always @(posedge i_clk)
			// The bit is automatically cleared on release from interrupt
			// or reset
			if ((i_reset)||(w_release_from_interrupt))
				r_ill_err_u <= 1'b0;
			// If the supervisor (or debugger) writes to this
			// register, clearing the bit, then clear it
			else if (((!alu_gie)||(dbgv))&&(wr_reg_ce)&&(wr_write_ucc))
				r_ill_err_u <=((ill_err_u)&&(wr_spreg_vl[`CPU_ILL_BIT]));
			else if ((alu_illegal)&&(alu_gie)&&(!clear_pipeline))
				r_ill_err_u <= 1'b1;

		assign	ill_err_u = r_ill_err_u;

	end endgenerate

	// Supervisor/interrupt bus error flag -- this will crash the CPU if
	// ever set.
	initial	ibus_err_flag = 1'b0;
	always @(posedge i_clk)
		if (i_reset)
			ibus_err_flag <= 1'b0;
		else if ((dbgv)&&(wr_write_scc))
			ibus_err_flag <= (ibus_err_flag)&&(wr_spreg_vl[`CPU_BUSERR_BIT]);
		else if ((bus_err)&&(!alu_gie))
			ibus_err_flag <= 1'b1;
	// User bus error flag -- if ever set, it will cause an interrupt to
	// supervisor mode.
	generate if (OPT_NO_USERMODE)
	begin

		assign	ubus_err_flag = 1'b0;

	end else begin : SET_USER_BUSERR

		reg	r_ubus_err_flag;

		initial	r_ubus_err_flag = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)||(w_release_from_interrupt))
				r_ubus_err_flag <= 1'b0;
			else if (((!alu_gie)||(dbgv))&&(wr_reg_ce)&&(wr_write_ucc))
				r_ubus_err_flag <= (ubus_err_flag)&&(wr_spreg_vl[`CPU_BUSERR_BIT]);
			else if ((bus_err)&&(alu_gie))
				r_ubus_err_flag <= 1'b1;

		assign	ubus_err_flag = r_ubus_err_flag;
	end endgenerate

	generate if (IMPLEMENT_DIVIDE != 0)
	begin : DIVERR
		reg	r_idiv_err_flag, r_udiv_err_flag;

		// Supervisor/interrupt divide (by zero) error flag -- this will
		// crash the CPU if ever set.  This bit is thus available for us
		// to be able to tell if/why the CPU crashed.
		initial	r_idiv_err_flag = 1'b0;
		always @(posedge i_clk)
			if (i_reset)
				r_idiv_err_flag <= 1'b0;
			else if ((dbgv)&&(wr_write_scc))
				r_idiv_err_flag <= (r_idiv_err_flag)&&(wr_spreg_vl[`CPU_DIVERR_BIT]);
			else if ((div_error)&&(!alu_gie))
				r_idiv_err_flag <= 1'b1;

		assign	idiv_err_flag = r_idiv_err_flag;

		if (OPT_NO_USERMODE)
		begin
			assign	udiv_err_flag = 1'b0;
		end else begin

			// User divide (by zero) error flag -- if ever set, it will
			// cause a sudden switch interrupt to supervisor mode.
			initial	r_udiv_err_flag = 1'b0;
			always @(posedge i_clk)
				if ((i_reset)||(w_release_from_interrupt))
					r_udiv_err_flag <= 1'b0;
				else if (((!alu_gie)||(dbgv))&&(wr_reg_ce)
						&&(wr_write_ucc))
					r_udiv_err_flag <= (r_udiv_err_flag)&&(wr_spreg_vl[`CPU_DIVERR_BIT]);
				else if ((div_error)&&(alu_gie))
					r_udiv_err_flag <= 1'b1;

			assign	udiv_err_flag = r_udiv_err_flag;
		end
	end else begin
		assign	idiv_err_flag = 1'b0;
		assign	udiv_err_flag = 1'b0;
	end endgenerate

	generate if (IMPLEMENT_FPU !=0)
	begin : FPUERR
		// Supervisor/interrupt floating point error flag -- this will
		// crash the CPU if ever set.
		reg		r_ifpu_err_flag, r_ufpu_err_flag;
		initial	r_ifpu_err_flag = 1'b0;
		always @(posedge i_clk)
			if (i_reset)
				r_ifpu_err_flag <= 1'b0;
			else if ((dbgv)&&(wr_write_scc))
				r_ifpu_err_flag <= (r_ifpu_err_flag)&&(wr_spreg_vl[`CPU_FPUERR_BIT]);
			else if ((fpu_error)&&(fpu_valid)&&(!alu_gie))
				r_ifpu_err_flag <= 1'b1;
		// User floating point error flag -- if ever set, it will cause
		// a sudden switch interrupt to supervisor mode.
		initial	r_ufpu_err_flag = 1'b0;
		always @(posedge i_clk)
			if ((i_reset)&&(w_release_from_interrupt))
				r_ufpu_err_flag <= 1'b0;
			else if (((!alu_gie)||(dbgv))&&(wr_reg_ce)
					&&(wr_write_ucc))
				r_ufpu_err_flag <= (r_ufpu_err_flag)&&(wr_spreg_vl[`CPU_FPUERR_BIT]);
			else if ((fpu_error)&&(alu_gie)&&(fpu_valid))
				r_ufpu_err_flag <= 1'b1;

		assign	ifpu_err_flag = r_ifpu_err_flag;
		assign	ufpu_err_flag = r_ufpu_err_flag;
	end else begin
		assign	ifpu_err_flag = 1'b0;
		assign	ufpu_err_flag = 1'b0;
	end endgenerate

	generate if (OPT_CIS)
	begin : GEN_IHALT_PHASE
		reg		r_ihalt_phase;

		initial	r_ihalt_phase = 0;
		always @(posedge i_clk)
			if (i_reset)
				r_ihalt_phase <= 1'b0;
			else if ((!alu_gie)&&(alu_pc_valid)&&(!clear_pipeline))
				r_ihalt_phase <= alu_phase;

		assign	ihalt_phase = r_ihalt_phase;
	end else begin : GEN_IHALT_PHASE

		assign	ihalt_phase = 1'b0;

	end endgenerate

	generate if ((!OPT_CIS) || (OPT_NO_USERMODE))
	begin : GEN_UHALT_PHASE

		assign	uhalt_phase = 1'b0;

	end else begin : GEN_UHALT_PHASE

		reg		r_uhalt_phase;

		initial	r_uhalt_phase = 1'b0;
		always @(posedge i_clk)
		if ((i_reset)||(w_release_from_interrupt))
			r_uhalt_phase <= 1'b0;
		else if ((alu_gie)&&(alu_pc_valid))
			r_uhalt_phase <= alu_phase;
		else if ((!alu_gie)&&(wr_reg_ce)&&(wr_write_pc)
				&&(wr_reg_id[4]))
			r_uhalt_phase <= wr_spreg_vl[1];

		assign	uhalt_phase = r_uhalt_phase;

	end endgenerate

	//
	// Write backs to the PC register, and general increments of it
	//	We support two: upc and ipc.  If the instruction is normal,
	// we increment upc, if interrupt level we increment ipc.  If
	// the instruction writes the PC, we write whichever PC is appropriate.
	//
	// Do we need to all our partial results from the pipeline?
	// What happens when the pipeline has gie and !gie instructions within
	// it?  Do we clear both?  What if a gie instruction tries to clear
	// a non-gie instruction?
	generate if (OPT_NO_USERMODE)
	begin

		assign	upc = {(AW+2){1'b0}};

	end else begin : SET_USER_PC

		reg	[(AW+1):0]	r_upc;

		always @(posedge i_clk)
			if ((wr_reg_ce)&&(wr_reg_id[4])&&(wr_write_pc))
				r_upc <= { wr_spreg_vl[(AW+1):2], 2'b00 };
			else if ((alu_gie)&&
					(((alu_pc_valid)&&(!clear_pipeline)&&(!alu_illegal))
					||(mem_pc_valid)))
				r_upc <= alu_pc;
		assign	upc = r_upc;
	end endgenerate

	initial	ipc = { RESET_BUS_ADDRESS, 2'b00 };
	always @(posedge i_clk)
	if (i_reset)
		ipc <= { RESET_BUS_ADDRESS, 2'b00 };
	else if ((wr_reg_ce)&&(!wr_reg_id[4])&&(wr_write_pc))
		ipc <= { wr_spreg_vl[(AW+1):2], 2'b00 };
	else if ((!alu_gie)&&(!alu_phase)&&
			(((alu_pc_valid)&&(!clear_pipeline)&&(!alu_illegal))
			||(mem_pc_valid)))
		ipc <= alu_pc;

	initial pf_pc = { RESET_BUS_ADDRESS, 2'b00 };
	always @(posedge i_clk)
	if (i_reset)
		pf_pc <= { RESET_BUS_ADDRESS, 2'b00 };
	else if ((w_switch_to_interrupt)
			||((!gie)&&((w_clear_icache)||(dbg_clear_pipe))))
		pf_pc <= { ipc[(AW+1):2], 2'b00 };
	else if ((w_release_from_interrupt)||((gie)&&((w_clear_icache)||(dbg_clear_pipe))))
		pf_pc <= { upc[(AW+1):2], 2'b00 };
	else if ((wr_reg_ce)&&(wr_reg_id[4] == gie)&&(wr_write_pc))
		pf_pc <= { wr_spreg_vl[(AW+1):2], 2'b00 };
	else if ((dcd_early_branch_stb)&&(!clear_pipeline))
		pf_pc <= { dcd_branch_pc[AW+1:2] + 1'b1, 2'b00 };
	else if ((new_pc)||((!pf_stalled)&&(pf_valid)))
		pf_pc <= { pf_pc[(AW+1):2] + 1'b1, 2'b00 };

	initial	last_write_to_cc = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		last_write_to_cc <= 1'b0;
	else
		last_write_to_cc <= (wr_reg_ce)&&(wr_write_cc);
	assign	cc_write_hold = (wr_reg_ce)&&(wr_write_cc)||(last_write_to_cc);

	// If we aren't pipelined, or equivalently if we have no cache, these
	// instructions will get quietly (or not so quietly) ignored by the
	// optimizer.
	initial	r_clear_icache = 1'b1;
	always @(posedge i_clk)
	if (i_reset)
		r_clear_icache <= 1'b0;
	else if ((r_halted)&&(i_clear_pf_cache))
		r_clear_icache <= 1'b1;
	else if ((wr_reg_ce)&&(wr_write_scc))
		r_clear_icache <=  wr_spreg_vl[`CPU_CLRCACHE_BIT];
	else
		r_clear_icache <= 1'b0;
	assign	w_clear_icache = r_clear_icache;

	initial	new_pc = 1'b1;
	always @(posedge i_clk)
		if ((i_reset)||(w_clear_icache)||(dbg_clear_pipe))
			new_pc <= 1'b1;
		else if (w_switch_to_interrupt)
			new_pc <= 1'b1;
		else if (w_release_from_interrupt)
			new_pc <= 1'b1;
		// else if ((wr_reg_ce)&&(wr_reg_id[4] == gie)&&(wr_write_pc))
		// Can't check for *this* PC here, since a user PC might be
		// loaded in the pipeline and hence rewritten.  Thus, while
		// I hate to do it, we'll need to clear the pipeline on any
		// PC write
		else if ((wr_reg_ce)&&(alu_gie == wr_reg_id[4])&&(wr_write_pc))
			new_pc <= 1'b1;
		else
			new_pc <= 1'b0;

	//
	// The debug write-back interface
	//{{{
	wire	[31:0]	w_debug_pc;
	generate if (OPT_NO_USERMODE)
	begin

		assign	w_debug_pc[(AW+1):0] = { ipc, 2'b00 };
	end else begin

		assign	w_debug_pc[(AW+1):0] = { (i_dbg_reg[4])
				? { upc[(AW+1):2], uhalt_phase, 1'b0 }
				: { ipc[(AW+1):2], ihalt_phase, 1'b0 } };
	end endgenerate

	generate
	if (AW<30)
		assign	w_debug_pc[31:(AW+2)] = 0;
	endgenerate

	generate if (OPT_NO_USERMODE)
	begin : NO_USER_SETDBG

		always @(posedge i_clk)
		begin
			o_dbg_reg <= regset[i_dbg_reg[3:0]];
			if (i_dbg_reg[3:0] == `CPU_PC_REG)
				o_dbg_reg <= w_debug_pc;
			else if (i_dbg_reg[3:0] == `CPU_CC_REG)
			begin
				o_dbg_reg[14:0] <= w_iflags;
				o_dbg_reg[15] <= 1'b0;
				o_dbg_reg[31:23] <= w_cpu_info;
				o_dbg_reg[`CPU_GIE_BIT] <= gie;
			end
		end
	end else begin : SETDBG

`ifdef	NO_DISTRIBUTED_RAM
		reg	[31:0]	pre_dbg_reg;
		always @(posedge i_clk)
			pre_dbg_reg <= regset[i_dbg_reg];

		always @(posedge i_clk)
		begin
			o_dbg_reg <= pre_dbg_reg;
			if (i_dbg_reg[3:0] == `CPU_PC_REG)
				o_dbg_reg <= w_debug_pc;
			else if (i_dbg_reg[3:0] == `CPU_CC_REG)
			begin
				o_dbg_reg[14:0] <= (i_dbg_reg[4])
						? w_uflags : w_iflags;
				o_dbg_reg[15] <= 1'b0;
				o_dbg_reg[31:23] <= w_cpu_info;
				o_dbg_reg[`CPU_GIE_BIT] <= gie;
			end
		end

`else
		always @(posedge i_clk)
		begin
			o_dbg_reg <= regset[i_dbg_reg];
			if (i_dbg_reg[3:0] == `CPU_PC_REG)
				o_dbg_reg <= w_debug_pc;
			else if (i_dbg_reg[3:0] == `CPU_CC_REG)
			begin
				o_dbg_reg[14:0] <= (i_dbg_reg[4])
						? w_uflags : w_iflags;
				o_dbg_reg[15] <= 1'b0;
				o_dbg_reg[31:23] <= w_cpu_info;
				o_dbg_reg[`CPU_GIE_BIT] <= gie;
			end
		end
`endif

	end endgenerate

	always @(posedge i_clk)
		o_dbg_cc <= { o_break, bus_err, gie, sleep };

	generate if (OPT_PIPELINED)
	begin
		always @(posedge i_clk)
			r_halted <= (i_halt)&&(!alu_phase)&&(!bus_lock)&&(
				// To be halted, any long lasting instruction
				// must be completed.
				(!pf_cyc)&&(!mem_busy)&&(!alu_busy)
					&&(!div_busy)&&(!fpu_busy)
				// Operations must either be valid, or illegal
				&&((op_valid)||(i_reset)||(dcd_illegal))
				// Decode stage must be either valid, in reset,
				// or producing an illelgal instruction
				&&((dcd_valid)||(i_reset)||(pf_illegal)));
	end else begin

		always @(posedge i_clk)
			r_halted <= (i_halt)&&(!alu_phase)&&((op_valid)||(i_reset));
	end endgenerate
`ifdef	NO_DISTRIBUTED_RAM
	reg	r_dbg_stall;
	initial	r_dbg_stall = 1'b1;

	always @(posedge i_clk)
	if (i_reset)
		r_dbg_stall <= 1'b1;
	else if (!r_halted)
		r_dbg_stall <= 1'b1;
	else
		r_dbg_stall <= (!i_dbg_we)||(!r_dbg_stall);

	assign	o_dbg_stall = !r_halted;
`else
	assign	o_dbg_stall = !r_halted;
`endif
	//}}}

	//}}}

	//
	//
	// Produce accounting outputs: Account for any CPU stalls, so we can
	// later evaluate how well we are doing.
	//
	//
	assign	o_op_stall = (master_ce)&&(op_stall);
	assign	o_pf_stall = (master_ce)&&(!pf_valid);
	assign	o_i_count  = (alu_pc_valid)&&(!clear_pipeline);

`ifdef	DEBUG_SCOPE
	//{{{

	reg		debug_trigger;
	initial	debug_trigger = 1'b0;
	always @(posedge i_clk)
		debug_trigger <= (!i_halt)&&(o_break);

	wire	[31:0]	debug_flags;
	assign debug_flags = { debug_trigger, 3'b101,
				master_ce, i_halt, o_break, sleep,
				gie, ibus_err_flag, trap, ill_err_i,
				w_clear_icache, pf_valid, pf_illegal, dcd_ce,
				dcd_valid, dcd_stalled, op_ce, op_valid,
				op_pipe, alu_ce, alu_busy, alu_wR,
				alu_illegal, alu_wF, mem_ce, mem_we,
				mem_busy, mem_pipe_stalled, (new_pc), (dcd_early_branch) };

	/*
	wire	[25:0]	bus_debug;
	assign	bus_debug = { debug_trigger,
			mem_ce, mem_we, mem_busy, mem_pipe_stalled,
			o_wb_gbl_cyc, o_wb_gbl_stb, o_wb_lcl_cyc, o_wb_lcl_stb,
				o_wb_we, i_wb_ack, i_wb_stall, i_wb_err,
			pf_cyc, pf_stb, pf_ack, pf_stall,
				pf_err,
			mem_cyc_gbl, mem_stb_gbl, mem_cyc_lcl, mem_stb_lcl,
				mem_we, mem_ack, mem_stall, mem_err
			};
	*/

	// Verilator lint_off UNUSED
	wire	[27:0]	dbg_pc, dbg_wb_addr;
	// Verilator lint_on  UNUSED
	generate if (AW-1 < 27)
	begin
		assign	dbg_pc[(AW-1):0] = pf_pc[(AW+1):2];
		assign	dbg_pc[27:AW] = 0;

		assign	dbg_wb_addr[(AW-1):0] = o_wb_addr;
		assign	dbg_wb_addr[27:AW] = 0;
	end else // if (AW-1 >= 27)
	begin
		assign	dbg_pc[27:0] = pf_pc[29:2];
		assign	dbg_wb_addr = o_wb_addr;
	end endgenerate

	always @(posedge i_clk)
	begin
		if ((i_halt)||(!master_ce)||(debug_trigger)||(o_break))
			o_debug <= debug_flags;
		else if ((mem_valid)||((!clear_pipeline)&&(!alu_illegal)
					&&(((alu_wR)&&(alu_valid))
						||(div_valid)||(fpu_valid))))
			o_debug <= { debug_trigger, 1'b0, wr_reg_id[3:0], wr_gpreg_vl[25:0]};
		else if (clear_pipeline)
			o_debug <= { debug_trigger, 3'b100, dbg_pc };
		else if ((o_wb_gbl_stb)|(o_wb_lcl_stb))
			o_debug <= {debug_trigger,  2'b11, o_wb_gbl_stb, o_wb_we,
				(o_wb_we)?o_wb_data[26:0] : dbg_wb_addr[26:0] };
		else
			o_debug <= debug_flags;
		// o_debug[25:0] <= bus_debug;
	end
	//}}}
`endif

	// Make verilator happy
	//{{{
	// verilator lint_off UNUSED
	wire	[56:0]	unused;
	assign	unused = { pf_new_pc,
		fpu_ce, pf_data, wr_spreg_vl[1:0],
		ipc[1:0], upc[1:0], pf_pc[1:0],
		dcd_rA, dcd_pipe, dcd_zI,
		dcd_A_stall, dcd_B_stall, dcd_F_stall,
		op_Rcc, op_pipe, op_lock, mem_pipe_stalled, prelock_stall,
		dcd_F };
	generate if (AW+2 < 32)
	begin
		wire	[31:(AW+2)] generic_ignore;
		assign generic_ignore = wr_spreg_vl[31:(AW+2)];
	end endgenerate
	// verilator lint_on  UNUSED
	//}}}

	// Formal methods
	//{{{
`ifdef	FORMAL
// PHASE_ONE is defined by default if nothing else is defined
// `define	PHASE_TWO
// `define	PHASE_THREE
// `define	PHASE_FOUR
// `define	PHASE_FIVE
//
`define	PHASE_ONE_ASSERT	assert
`define	PHASE_TWO_ASSERT	assert
`define	PHASE_THR_ASSERT	assert
`define	PHASE_FOR_ASSERT	assert
`define	PHASE_FIV_ASSERT	assert
//
//
//
`ifdef	PHASE_TWO
`undef	PHASE_ONE_ASSERT
`define	PHASE_ONE_ASSERT	assume

`ifdef	PHASE_THREE
`undef	PHASE_TWO_ASSERT
`define	PHASE_TWO_ASSERT	assume

`ifdef	PHASE_FOUR
`undef	PHASE_THR_ASSERT
`define	PHASE_THR_ASSERT	assume

`ifdef	PHASE_FIVE
`undef	PHASE_FOR_ASSERT
`define	PHASE_FOR_ASSERT	assume

`endif // PHASE_FOUR
`endif // PHASE_THREE
`endif // PHASE_TWO
`endif // PHASE_ONE

	////////////////////////////////////////////////////////////////
	//
	//
	// Formal methods section
	//
	//
	////////////////////////////////////////////////////////////////
	reg	f_past_valid;
	initial	f_past_valid = 1'b0;
	always @(posedge i_clk)
		f_past_valid <= 1'b1;

	initial	assume(i_reset);
	initial	assume(!i_wb_ack);
	initial	assume(!i_wb_err);
	always @(posedge i_clk)
	if (!f_past_valid)
	begin
		assume(i_reset);
		assume(!i_wb_ack);
		assume(!i_wb_err);
	end

	//////////////////////////////////////////////
	//
	//
	// Problem limiting assumptions
	//
	//
	//////////////////////////////////////////////
	//
	// Take care that the assumptions below are actually representative
	// of how the CPU is used.  One "careless" assumption could render
	// the proof meaningless.
	//
	// Because of the consequences of a careless assumption, we'll work
	// to place all of our assumptions at the beginning of the formal
	// properties for any phase.
	//

	// If the CPU is not halted, the debug interface will not try writing
	// to the CPU, nor will it try to issue a clear i-cache command
	always @(*)
	if (!r_halted)
	begin
		assume(!i_dbg_we);
		assume(!i_clear_pf_cache);
	end

	// A debug write will only take place during a CPUI halt
	always @(posedge i_clk)
	if (i_dbg_we)
		assume(i_halt);

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_dbg_we))&&(!$past(o_dbg_stall)))
		assume(i_halt);

	always @(*)
	if ((!r_halted)||(!i_halt))
		assume(!i_clear_pf_cache);

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_clear_pf_cache)))
		assume(i_halt);


	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_dbg_we))&&($past(o_dbg_stall)))
		assume(($stable(i_dbg_we))&&($stable(i_dbg_data)));


	// Any attempt to set the PC will leave the bottom two bits clear
	always @(*)
	if ((wr_reg_ce)&&(wr_reg_id[3:0] == `CPU_PC_REG))
		assume(wr_gpreg_vl[1:0] == 2'b00);

	// Once a halt is requested, the halt request will remain active until
	// the CPU comes to a complete halt.
	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_halt))&&(!$past(r_halted)))
		assume(i_halt);

	// Once asserted, an interrupt will stay asserted while the CPU is
	// in user mode
	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_interrupt)))
	begin
		if ($past(gie))
			assume(i_interrupt);
	end

	always @(*)
		assume(!i_dbg_we);


///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
////                                                                       ////
////                                                                       ////
////  Formal proof, phase one                                              ////
////                                                                       ////
////  This section of the proof is built around fairly simple properties.  ////
////  It is focused upon making sure that the assertions of the component  ////
////  properties hold.  The goal here is to avoid any significantly        ////
////  complex properties--we'll catch those in the next section.           ////
////                                                                       ////
////                                                                       ////
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
	always @(posedge i_clk)
	if ((!f_past_valid)||($past(i_reset)))
	begin
		// Initial assertions
		`PHASE_ONE_ASSERT(!pf_valid);
		`PHASE_ONE_ASSERT(!dcd_phase);
		`PHASE_ONE_ASSERT(!op_phase);
		`PHASE_ONE_ASSERT(!alu_phase);
		//
		`PHASE_ONE_ASSERT(!pf_valid);
		`PHASE_ONE_ASSERT(!dcd_valid);
		`PHASE_ONE_ASSERT(!op_valid);
		`PHASE_ONE_ASSERT(!op_valid_mem);
		`PHASE_ONE_ASSERT(!op_valid_div);
		`PHASE_ONE_ASSERT(!op_valid_alu);
		`PHASE_ONE_ASSERT(!op_valid_fpu);
		//
		`PHASE_ONE_ASSERT(!alu_valid);
		`PHASE_ONE_ASSERT(!alu_busy);
		//
		`PHASE_ONE_ASSERT(!mem_valid);
		`PHASE_ONE_ASSERT(!mem_busy);
		`PHASE_ONE_ASSERT(!bus_err);
		//
		`PHASE_ONE_ASSERT(!div_valid);
		`PHASE_ONE_ASSERT(!div_busy);
		`PHASE_ONE_ASSERT(!div_error);
		//
		`PHASE_ONE_ASSERT(!fpu_valid);
		`PHASE_ONE_ASSERT(!fpu_busy);
		`PHASE_ONE_ASSERT(!fpu_error);
		//
		`PHASE_ONE_ASSERT(!ill_err_i);
		`PHASE_ONE_ASSERT(!ill_err_u);
		`PHASE_ONE_ASSERT(!idiv_err_flag);
		`PHASE_ONE_ASSERT(!udiv_err_flag);
		`PHASE_ONE_ASSERT(!ibus_err_flag);
		`PHASE_ONE_ASSERT(!ubus_err_flag);
		`PHASE_ONE_ASSERT(!ifpu_err_flag);
		`PHASE_ONE_ASSERT(!ufpu_err_flag);
		`PHASE_ONE_ASSERT(!ihalt_phase);
		`PHASE_ONE_ASSERT(!uhalt_phase);
	end

	always @(*)
	begin
		if (pf_valid)		`PHASE_ONE_ASSERT(f_past_valid);
		if (dcd_valid)		`PHASE_ONE_ASSERT(f_past_valid);
		if (alu_pc_valid)	`PHASE_ONE_ASSERT(f_past_valid);
		if (mem_valid)		`PHASE_ONE_ASSERT(f_past_valid);
		if (div_valid)		`PHASE_ONE_ASSERT(f_past_valid);
		if (fpu_valid)		`PHASE_ONE_ASSERT(f_past_valid);
		if (w_op_valid)		`PHASE_ONE_ASSERT(f_past_valid);
		if (mem_busy)		`PHASE_ONE_ASSERT(f_past_valid);
		if (mem_rdbusy)		`PHASE_ONE_ASSERT(f_past_valid);
		if (div_busy)		`PHASE_ONE_ASSERT(f_past_valid);
		if (fpu_busy)		`PHASE_ONE_ASSERT(f_past_valid);
	end

	////////////////////////////////////////////////////////////////
	//
	//
	// Pipeline signaling check
	//
	//
	////////////////////////////////////////////////////////////////
	//
	//

	always @(posedge i_clk)
	if (clear_pipeline)
	begin
		// `PHASE_ONE_ASSERT(!alu_ce);
		`PHASE_ONE_ASSERT(!mem_ce);
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(clear_pipeline)))
	begin
		`PHASE_ONE_ASSERT(!alu_busy);
		`PHASE_ONE_ASSERT(!div_busy);
		`PHASE_ONE_ASSERT(!mem_busy);
		`PHASE_ONE_ASSERT(!fpu_busy);
		//
		`PHASE_ONE_ASSERT(!alu_valid);
		`PHASE_ONE_ASSERT(!div_valid);
		`PHASE_ONE_ASSERT(!fpu_valid);
	end

	always @(*)
	if (dcd_ce)
		`PHASE_ONE_ASSERT((op_ce)||(!dcd_valid));

	always @(*)
	if ((op_ce)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT((adf_ce_unconditional)||(mem_ce)||(!op_valid));

//	always @(*)
//	if ((wr_reg_ce)&&(wr_reg_id[3:1] == 3'h7))
//		`PHASE_ONE_ASSERT((adf_ce_unconditional)||(mem_ce)||(!op_valid));

	////////////////////////////////////////////////
	//
	// Assertions about the Program counter
	//
	////////////////////////////////////////////////
	always @(*)
		`PHASE_ONE_ASSERT(pf_instruction_pc[1:0]==2'b00);

	always @(*)
		`PHASE_ONE_ASSERT(!dcd_pc[0]);

	always @(*)
	if ((dcd_valid)&&(!dcd_illegal))
		`PHASE_ONE_ASSERT((!dcd_pc[1])||(dcd_phase));

	always @(*)
	if (dcd_valid)
	begin
		if (dcd_phase)
		begin
			`PHASE_ONE_ASSERT(dcd_pc[1]);
			`PHASE_ONE_ASSERT(f_dcd_hidden_state[31]);
		end
	end

	always @(*)
	begin
		`PHASE_ONE_ASSERT(dcd_branch_pc[1:0] == 2'b00);
		`PHASE_ONE_ASSERT(!op_pc[0]);
	end

	always @(*)
		`PHASE_ONE_ASSERT(!alu_pc[0]);


	////////////////////////////////////////////////
	//
	// Assertions about the prefetch (output) stage
	//
	////////////////////////////////////////////////
	always @(posedge i_clk)
	if ((!clear_pipeline)&&(pf_valid))
		`PHASE_ONE_ASSERT(pf_gie == gie);

	always @(*)
	if ((pf_valid)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT(pf_gie == gie);

	////////////////////////////////////////////////
	//
	// Assertions about the decode stage
	//
	////////////////////////////////////////////////
	//
	//
	always @(posedge i_clk)
	if ((dcd_valid)&&(!dcd_illegal)&&(!clear_pipeline))
	begin
		`PHASE_ONE_ASSERT(dcd_gie == gie);
		if ((gie)||(dcd_phase))
		begin
			`PHASE_ONE_ASSERT((!dcd_wR)||(dcd_R[4]==dcd_gie));
			`PHASE_ONE_ASSERT((!dcd_rA)||(dcd_A[4]==dcd_gie));
			`PHASE_ONE_ASSERT((!dcd_rB)||(dcd_B[4]==dcd_gie));
		end else if ((!dcd_early_branch)&&((dcd_M)
				||(dcd_DIV)||(dcd_FP)||(!dcd_wR)))
			`PHASE_ONE_ASSERT(!dcd_gie);
		if ((dcd_ALU)&&(dcd_opn==`CPU_MOV_OP))
			`PHASE_ONE_ASSERT(((!dcd_rA)&&(dcd_wR))
				||((!dcd_rA)&&(!dcd_rB)&&(!dcd_wR)));
		else if (dcd_ALU)
			`PHASE_ONE_ASSERT(
				(gie == dcd_R[4])
				&&(gie == dcd_A[4])
				&&((!dcd_rB)||(gie == dcd_B[4]))
				&&(dcd_gie == gie));
	end

	always @(*)
	if ((dcd_valid)&&(!dcd_illegal))
	begin
		if (dcd_opn == 4'h0)
			`PHASE_ONE_ASSERT((dcd_ALU)&&(dcd_rA));
		if (dcd_opn == 4'h1)
			`PHASE_ONE_ASSERT((dcd_ALU)&&(dcd_rA));
		if ((dcd_opn >= 4'h2)&&(dcd_opn <= 4'h7))
		begin
			if (dcd_opn[0])
			begin
				`PHASE_ONE_ASSERT(
					((dcd_ALU)&&(dcd_wR)&&(dcd_rA))
					||((dcd_M)&&(!dcd_wR)&&(dcd_rA)));
			end else begin
				`PHASE_ONE_ASSERT(
					((dcd_ALU)&&(dcd_wR)&&(dcd_rA))
					||((dcd_M)&&(dcd_wR)&&(!dcd_rA)));
			end
		end
		if ((dcd_opn >= 4'h8)&&(dcd_opn <= 4'hb))
			`PHASE_ONE_ASSERT((dcd_ALU)&&(dcd_wR));
		if (dcd_opn == 4'hc)
			`PHASE_ONE_ASSERT(((dcd_ALU)&&(dcd_wR))
					||((!dcd_ALU)&&(!dcd_M)&&(!dcd_DIV)&&(dcd_break)&&(!dcd_wR)));
		if (dcd_opn == 4'hd)
			`PHASE_ONE_ASSERT(((dcd_ALU)&&(!dcd_rA))
					||((!dcd_ALU)&&(!dcd_M)&&(!dcd_DIV)&&(dcd_lock)&&(!dcd_wR)&&(!dcd_rA)));
		if (dcd_opn == 4'he)
			`PHASE_ONE_ASSERT(((dcd_DIV)&&(dcd_wR)&&(dcd_rA)&&(dcd_R[3:1] != 3'h7))
					||((!dcd_ALU)&&(!dcd_M)&&(!dcd_DIV)&&(dcd_sim)&&(!dcd_wR)));
		if (dcd_opn == 4'hf)
			`PHASE_ONE_ASSERT((dcd_DIV)&&(dcd_wR)&&(dcd_rA)&&(dcd_R[3:1] != 3'h7));
	end

	always @(*)
	if ((op_valid)&&(op_rA)&&(op_Aid[3:1] == 3'h7)&&(!clear_pipeline)
				&&(op_Aid[4:0] != { gie, 4'hf}))
		`PHASE_ONE_ASSERT(!pending_sreg_write);
	always @(*)
	if ((op_valid)&&(op_rB)&&(op_Bid[3:1] == 3'h7)&&(!clear_pipeline)
				&&(op_Bid[4:0] != { gie, 4'hf}))
		`PHASE_ONE_ASSERT(!pending_sreg_write);

	//
	// Only one type of instruction can ever be valid at any given time
	//
	always @(*)
	if ((dcd_valid)&&(!dcd_illegal))
	begin
		if (dcd_M)
			`PHASE_ONE_ASSERT((!dcd_ALU)&&(!dcd_FP)&&(!dcd_lock)&&(!dcd_break)&&(!dcd_sim)&&(!dcd_DIV));
		if (dcd_ALU)
			`PHASE_ONE_ASSERT((!dcd_DIV)&&(!dcd_FP)&&(!dcd_lock)&&(!dcd_sim)&&(!dcd_break));
		if (dcd_FP)
			`PHASE_ONE_ASSERT((!dcd_lock)&&(!dcd_sim)&&(!dcd_break));
		if (dcd_sim)
			`PHASE_ONE_ASSERT((!dcd_lock)&&(!dcd_break));
		if (dcd_lock)
			`PHASE_ONE_ASSERT(!dcd_break);
	end


	//
	// An initial check that the operands are reasonably decoded.
	//
	always @(*)
	if ((dcd_valid)&&(!dcd_illegal)&&(!clear_pipeline))
	begin
		`PHASE_ONE_ASSERT(dcd_Rcc == (dcd_R[4:0] == { dcd_gie, 4'he }));
		`PHASE_ONE_ASSERT(dcd_Rpc == (dcd_R[4:0] == { dcd_gie, 4'hf }));

		`PHASE_ONE_ASSERT(dcd_Acc == (dcd_A[4:0] == { dcd_gie, 4'he }));
		`PHASE_ONE_ASSERT(dcd_Apc == (dcd_A[4:0] == { dcd_gie, 4'hf }));

		if (dcd_rB)
		begin
			`PHASE_ONE_ASSERT(dcd_Bcc == (dcd_B[3:0] == 4'he));
			`PHASE_ONE_ASSERT(dcd_Bpc == (dcd_B[3:0] == 4'hf));
		end else begin
			`PHASE_ONE_ASSERT(!dcd_Bcc);
			`PHASE_ONE_ASSERT(!dcd_Bpc);
		end

		`PHASE_ONE_ASSERT(dcd_R == dcd_A);
	end

	//
	// Let's check that we have the GIE register right.
	//
	always @(*)
	if ((dcd_valid)&&(!dcd_illegal)&&(!clear_pipeline)&&((!dcd_ALU)
			||(dcd_opn != `CPU_MOV_OP)))
	begin
		`PHASE_ONE_ASSERT((dcd_gie == gie)||(clear_pipeline));
		`PHASE_ONE_ASSERT((!dcd_wR)||(dcd_R[4] == dcd_gie));
		`PHASE_ONE_ASSERT((!dcd_rA)||(dcd_A[4] == dcd_gie));
		`PHASE_ONE_ASSERT((!dcd_rB)||(dcd_B[4] == dcd_gie));
	end

	always @(*)
	if ((dcd_valid)&&(dcd_M)&&(!clear_pipeline))
	begin
		`PHASE_ONE_ASSERT((dcd_gie == gie)||(clear_pipeline));
		`PHASE_ONE_ASSERT(dcd_opn[0] == !dcd_wR);
		`PHASE_ONE_ASSERT(dcd_opn[0] ==  dcd_rA);
		`PHASE_ONE_ASSERT(dcd_wF == 1'b0);
		`PHASE_ONE_ASSERT(dcd_opn[2:1] != 2'b00);
	end

	always @(*)
	if ((dcd_valid)&&(!dcd_illegal)&&(dcd_phase)&&(!clear_pipeline))
	begin
		`PHASE_ONE_ASSERT(!dcd_DIV);
		`PHASE_ONE_ASSERT((!dcd_wR)||(dcd_R[4] == dcd_gie));
		`PHASE_ONE_ASSERT((!dcd_rA)||(dcd_A[4] == dcd_gie));
		`PHASE_ONE_ASSERT((!dcd_rB)||(dcd_B[4] == dcd_gie));
	end

	always @(*)
	if (dcd_valid)
		`PHASE_ONE_ASSERT(dcd_F[3] == (dcd_F[2:0] == 3'b000));

	always @(*)
	if ((dcd_valid)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT(dcd_gie == gie);

	always @(*)
	if ((dcd_valid)&&(dcd_DIV)&&(!clear_pipeline)&&(!dcd_illegal))
	begin
		`PHASE_ONE_ASSERT(dcd_R[3:1] != 3'h7);
		`PHASE_ONE_ASSERT(dcd_R[4] == dcd_gie);
		`PHASE_ONE_ASSERT(dcd_wR);
		`PHASE_ONE_ASSERT(dcd_rA);
		`PHASE_ONE_ASSERT((dcd_wF)||(!dcd_F[3]));
	end

	always @(*)
	if ((dcd_valid)&&(!dcd_illegal)&&(dcd_ALU))
	begin
		if ((dcd_opn != `CPU_SUB_OP)
			&&(dcd_opn != `CPU_AND_OP)
			&&(dcd_opn != `CPU_MOV_OP))
		begin
			`PHASE_ONE_ASSERT(dcd_wR);
		end
		if ((dcd_opn != `CPU_MOV_OP)&&(dcd_opn != `CPU_BREV_OP))
			`PHASE_ONE_ASSERT(dcd_rA);
		`PHASE_ONE_ASSERT(!dcd_lock);
		`PHASE_ONE_ASSERT(!dcd_break);
	end

	always @(*)
	if ((dcd_valid)&&(dcd_M)&&(dcd_pipe)&&(!dcd_illegal)&&(!alu_illegal)
			&&(!break_pending)&&(!clear_pipeline))
	begin
		if (op_valid_mem)
		begin
			`PHASE_ONE_ASSERT(op_opn[0]   == dcd_opn[0]);
			`PHASE_ONE_ASSERT((!dcd_rB)
				||(op_Bid[4:0] == dcd_B[4:0]));
			`PHASE_ONE_ASSERT(op_rB  == dcd_rB);
		end
		`PHASE_ONE_ASSERT(dcd_B[4] == dcd_gie);
	end

	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(mem_busy)&&(!mem_rdbusy))
		`PHASE_ONE_ASSERT(op_opn[0] == 1'b1);

	always @(*)
	if ((dcd_valid)&&(!dcd_M))
		`PHASE_ONE_ASSERT((dcd_illegal)||(!dcd_pipe));

	wire	[31:0]	f_dcd_mem_addr, f_pipe_addr_diff;
	assign	f_dcd_mem_addr = w_op_BnI+dcd_I;
	assign	f_pipe_addr_diff = f_dcd_mem_addr - op_Bv;

	always @(posedge i_clk)
	if ((f_past_valid)&&($past(dcd_early_branch))&&(!dcd_early_branch)
			&&(dcd_valid))
		`PHASE_ONE_ASSERT(!dcd_pipe);
	always @(*)
	if ((dcd_valid)&&(dcd_early_branch))
		`PHASE_ONE_ASSERT(!dcd_M);
	always @(*)
	if ((dcd_valid)&&(dcd_pipe)&&(w_op_valid))
	begin
		// `PHASE_ONE_ASSERT((dcd_A[3:1] != 3'h7)||(dcd_opn[0]));
		`PHASE_ONE_ASSERT(dcd_B[3:1] != 3'h7);
		`PHASE_ONE_ASSERT(dcd_rB);
		`PHASE_ONE_ASSERT(dcd_M);
		`PHASE_ONE_ASSERT(dcd_B == op_Bid);
		if (op_valid)
			`PHASE_ONE_ASSERT((op_valid_mem)||(op_illegal));
		if (((op_valid_mem)||(mem_busy))&&(dcd_rB)
			&&(!op_illegal)&&(!dcd_illegal)
			&&(!dbg_clear_pipe)&&(!clear_pipeline))
			`PHASE_ONE_ASSERT(f_pipe_addr_diff[AW+1:0] <= 4);
		if (op_valid_mem)
		begin
			`PHASE_ONE_ASSERT((dcd_I[AW+1:3] == 0)
				||(!alu_busy)||(!div_busy)
				||(!alu_wR)||(alu_reg != dcd_B));
			`PHASE_ONE_ASSERT((!op_wR)||(op_Aid != op_Bid));
		end
	end

	//
	// Decode option processing
	//

	// OPT_CIS ... the compressed instruction set
	always @(*)
	if ((!OPT_CIS)&&(dcd_valid))
	begin
		`PHASE_ONE_ASSERT(!dcd_phase);
		`PHASE_ONE_ASSERT(dcd_pc[1:0] == 2'b0);
	end

	always @(*)
	if ((dcd_valid)&&(dcd_phase))
		`PHASE_ONE_ASSERT(dcd_F == 4'h8);


	// OPT_LOCK
	always @(*)
	if ((!OPT_LOCK)&&(dcd_valid))
		`PHASE_ONE_ASSERT(!dcd_lock);

	// EARLY_BRANCHING
	always @(*)
	if (!EARLY_BRANCHING)
		`PHASE_ONE_ASSERT((!dcd_early_branch)
					&&(!dcd_early_branch_stb)
					&&(!dcd_ljmp));

	// IMPLEMENT_MULTIPLY
	always @(*)
	if ((IMPLEMENT_MPY == 0)&&(dcd_valid)&&(!dcd_illegal))
	begin
		`PHASE_ONE_ASSERT(dcd_opn != 4'ha);
		`PHASE_ONE_ASSERT(dcd_opn != 4'hb);
		`PHASE_ONE_ASSERT(dcd_opn != 4'hc);
	end

	always @(*)
	if (dcd_valid)
		`PHASE_ONE_ASSERT(dcd_zI == (dcd_I == 0));

	// IMPLEMENT_DIVIDE
	always @(*)
	if (!IMPLEMENT_DIVIDE)
		`PHASE_ONE_ASSERT(!dcd_DIV);

	always @(*)
	if ((dcd_DIV)&&(dcd_valid)&&(!dcd_illegal))
		`PHASE_ONE_ASSERT(dcd_wR);

	always @(*)
	if (!IMPLEMENT_DIVIDE)
		`PHASE_ONE_ASSERT((!dcd_DIV)&&(!op_valid_div)
			&&(!div_valid)&&(!div_error));
	else if (op_valid_div)
	begin
		`PHASE_ONE_ASSERT(!op_illegal);
		if ((!alu_illegal)&&(!ill_err_i))
			`PHASE_ONE_ASSERT(op_wR);
	end

	////////////////////////////////////////////////
	//
	// Assertions about the op stage
	//
	////////////////////////////////////////////////
	//
	//
	always @(*)
	if ((!OPT_CIS)&&(op_valid))
		`PHASE_ONE_ASSERT((!op_phase)||(op_illegal));
	always @(*)
	if ((!OPT_CIS)&&(op_valid))
		`PHASE_ONE_ASSERT(op_pc[1:0] == 2'b0);
	always @(*)
	if ((!OPT_LOCK)&&(op_valid))
		`PHASE_ONE_ASSERT((!op_lock)||(op_illegal));

	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(mem_rdbusy))
		`PHASE_ONE_ASSERT(op_opn[0] == 1'b0);

	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(mem_busy)&&(!mem_rdbusy))
		`PHASE_ONE_ASSERT(op_opn[0] == 1'b1);
	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(mem_rdbusy))
		`PHASE_ONE_ASSERT((OPT_LGDCACHE==0)||(mem_wreg != op_Bid));
	always @(*)
	if (op_ce)
		`PHASE_ONE_ASSERT((dcd_valid)||(dcd_illegal)||(dcd_early_branch));
	always @(*)
	if ((IMPLEMENT_MPY == 0)&&(op_valid)&&(!op_illegal))
	begin
		`PHASE_ONE_ASSERT(op_opn != 4'ha);
		`PHASE_ONE_ASSERT(op_opn != 4'hb);
		`PHASE_ONE_ASSERT(op_opn != 4'hc);
	end

	always @(*)
	if (mem_ce)
		`PHASE_ONE_ASSERT((op_valid)&&(op_valid_mem)&&(!op_illegal));
	else if ((op_valid_mem)||(op_valid_div)||(op_valid_fpu))
		`PHASE_ONE_ASSERT(!op_illegal);
	always @(*)
	if (div_ce)
		`PHASE_ONE_ASSERT((op_valid_div)&&(op_wR));
	always @(*)
	if ((op_valid)&&(op_phase))
	begin
		`PHASE_ONE_ASSERT(!op_valid_div);
		`PHASE_ONE_ASSERT(r_op_F == 7'h0);
	end

	always @(*)
	if (op_valid)
	begin
		if (op_valid_alu)
			`PHASE_ONE_ASSERT((!op_valid_mem)&&(!op_valid_fpu)
					&&(!op_sim)&&(!op_break)&&(!op_lock));
		if (op_valid_mem)
			`PHASE_ONE_ASSERT((!op_valid_fpu)&&(!op_sim)
				&&(!op_break)&&(!op_lock)&&(!op_illegal));
		if (op_valid_fpu)
			`PHASE_ONE_ASSERT((!op_sim)&&(!op_break)&&(!op_lock)&&(!op_illegal));
		if (op_sim)
			`PHASE_ONE_ASSERT((!op_break)&&(!op_lock)&&(!op_illegal));
		if (op_break)
			`PHASE_ONE_ASSERT((!op_lock)&&(!op_illegal));
		if (op_illegal)
			`PHASE_ONE_ASSERT(op_valid_alu);
	end

	// always @(posedge i_clk)
	// if ((f_past_valid)&&(!$past(op_valid_mem)))
		// `PHASE_ONE_ASSERT((!op_pipe)||(op_illegal));


	reg	f_op_zI;
	always @(posedge i_clk)
	if (op_ce)
		f_op_zI <= dcd_zI;

	always @(*)
		`PHASE_ONE_ASSERT((!wr_reg_ce)||(wr_reg_id != op_Bid)
				||(!op_rB)||(f_op_zI)||(!op_valid)
				||(dbg_clear_pipe));
	always @(*)
	if ((f_past_valid)&&(!f_op_zI)&&(mem_rdbusy)&&(op_valid)&&(op_rB))
		`PHASE_ONE_ASSERT((OPT_LGDCACHE==0)||(mem_wreg != op_Bid));
	always @(*)
	if ((dcd_valid)&&(dcd_pipe)&&(op_valid_mem)&&(f_op_zI))
		`PHASE_ONE_ASSERT(dcd_I <= 4);
	always @(*)
	if ((dcd_valid)&&(dcd_pipe)&&(f_op_zI))
		`PHASE_ONE_ASSERT(dcd_I <= 4);
	always @(*)
	if ((dcd_valid)&&(dcd_pipe)&&(!op_valid)&&(mem_rdbusy))
		`PHASE_ONE_ASSERT(mem_wreg != dcd_B);
	always @(*)
	if ((op_valid)&&(op_rB)&&(!f_op_zI)&&((mem_rdbusy)||(mem_valid)))
		`PHASE_ONE_ASSERT((OPT_LGDCACHE==0)||(mem_wreg != op_Bid));

	always @(*)
	if ((op_valid)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT(op_gie == gie);

	always @(*)
	if ((op_valid_alu)&&(!op_illegal))
	begin
		if ((op_opn != `CPU_SUB_OP)
			&&(op_opn != `CPU_AND_OP)
			&&(op_opn != `CPU_MOV_OP))
		begin
			`PHASE_ONE_ASSERT(op_wR);
		end
		if ((op_opn != `CPU_MOV_OP)&&(op_opn != `CPU_BREV_OP))
			`PHASE_ONE_ASSERT(op_rA);
	end

	always @(*)
	if ((op_valid)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT(op_gie == gie);

	always @(*)
	if (op_valid_mem)
	begin
		`PHASE_ONE_ASSERT(op_wR == !op_opn[0]);
		`PHASE_ONE_ASSERT(op_wF == 1'b0);
		`PHASE_ONE_ASSERT(op_rA ==  op_opn[0]);
		`PHASE_ONE_ASSERT(op_opn[2:1] != 2'b00);
	end

	always @(*)
	if (op_valid_div)
	begin
		`PHASE_ONE_ASSERT((op_wR)&&(op_rA));
		`PHASE_ONE_ASSERT((op_wF)||(op_F != 7'h0));
	end

	always @(posedge i_clk)
	if (op_valid_div)
		`PHASE_ONE_ASSERT(op_R[3:1] != 3'h7);


	always @(posedge i_clk)
	if ((op_valid)&&(!op_illegal)
			&&(!alu_illegal)&&(!ill_err_i)&&(!clear_pipeline))
	begin
		`PHASE_ONE_ASSERT(op_gie == gie);
		if ((gie)||(op_phase))
		begin
			`PHASE_ONE_ASSERT((!op_wR)||(op_R[4] == gie));
			`PHASE_ONE_ASSERT((!op_rA)||(op_Aid[4] == gie));
			`PHASE_ONE_ASSERT((!op_rB)||(op_Bid[4] == gie));
		end else if (((op_valid_mem)
				||(op_valid_div)||(op_valid_fpu)
				||((op_valid_alu)&&(op_opn!=`CPU_MOV_OP))))
		begin
			`PHASE_ONE_ASSERT((!op_wR)||(op_R[4] == gie));
			`PHASE_ONE_ASSERT((!op_rA)||(op_Aid[4] == gie));
			`PHASE_ONE_ASSERT((!op_rB)||(op_Bid[4] == gie));
		end
	end

	always @(posedge i_clk)
	if (op_valid)
	begin
		// `PHASE_ONE_ASSERT(|{op_illegal,op_valid_alu,op_valid_div,
		// 			op_valid_fpu,op_break,op_lock, op_sim});
		if (op_valid_mem)
			`PHASE_ONE_ASSERT(3'b000=={op_valid_alu, op_valid_div, op_valid_fpu });
		else if (op_valid_alu)
			`PHASE_ONE_ASSERT(2'b00 =={op_valid_div, op_valid_fpu });
		else if (op_valid_div)
			`PHASE_ONE_ASSERT(!op_valid_fpu);

		if (op_illegal)
			`PHASE_ONE_ASSERT((!op_valid_div)
				&&(!op_valid_fpu)&&(!op_lock));
	end else if ((!$past(op_illegal))&&(!clear_pipeline)&&(!pending_interrupt))
		`PHASE_ONE_ASSERT(!op_illegal);

	always @(*)
	begin
		if (alu_ce)
			`PHASE_ONE_ASSERT(adf_ce_unconditional);
		if (div_ce)
			`PHASE_ONE_ASSERT(adf_ce_unconditional);
		if (fpu_ce)
			`PHASE_ONE_ASSERT(adf_ce_unconditional);

		if ((op_valid)&&(op_illegal))
			`PHASE_ONE_ASSERT(op_valid_alu);
	end

	always @(*)
	if ((ibus_err_flag)||(ill_err_i)||(idiv_err_flag))
	begin
		`PHASE_ONE_ASSERT(master_stall);
		`PHASE_ONE_ASSERT(!mem_ce);
		`PHASE_ONE_ASSERT(!alu_ce);
		`PHASE_ONE_ASSERT(!div_ce);
		`PHASE_ONE_ASSERT(!adf_ce_unconditional);
	end

	always @(posedge i_clk)
	if ((adf_ce_unconditional)||(mem_ce))
		`PHASE_ONE_ASSERT(op_valid);

	always @(*)
	if ((op_valid_alu)&&(!adf_ce_unconditional)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT(!op_ce);

	always @(*)
	if ((op_valid_div)&&(!adf_ce_unconditional))
		`PHASE_ONE_ASSERT(!op_ce);

	always @(posedge i_clk)
		if (alu_stall)
			`PHASE_ONE_ASSERT(!alu_ce);
	always @(posedge i_clk)
		if (mem_stalled)
			`PHASE_ONE_ASSERT(!mem_ce);
	always @(posedge i_clk)
		if (div_busy)
			`PHASE_ONE_ASSERT(!div_ce);

	always @(*)
	if ((!i_reset)&&(break_pending)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT((op_valid)&&(op_break));

	wire	[AW-1:0]	f_next_mem, f_op_mem_addr;
	assign	f_next_mem    = mem_addr + 1'b1;
	assign	f_op_mem_addr = op_Bv[AW+1:2];
	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(mem_busy)&&(OPT_LGDCACHE == 0))
		`PHASE_ONE_ASSERT((f_op_mem_addr == mem_addr)
			||(f_op_mem_addr == f_next_mem));
	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(mem_valid))
		`PHASE_ONE_ASSERT(op_Bid != mem_wreg);

	always @(*)
	if ((op_valid_mem)&&(op_pipe)&&(alu_busy||alu_valid))
		`PHASE_ONE_ASSERT((!alu_wR)||(op_Bid != alu_reg));

	always @(*)
	if ((dcd_valid)&&(dcd_pipe))
		`PHASE_ONE_ASSERT((op_Aid[3:1] != 3'h7)||(op_opn[0]));

	always @(*)
	if ((op_valid)&(!op_valid_mem))
		`PHASE_ONE_ASSERT((op_illegal)||(!op_pipe));

	always @(posedge i_clk)
	if ((f_past_valid)&&(op_valid_mem)&&(op_pipe))
	begin
		if ((mem_busy)&&(OPT_LGDCACHE==0))
		`PHASE_ONE_ASSERT((op_Bv[(AW+1):2]==mem_addr[(AW-1):0])
			||(op_Bv[(AW+1):2]==mem_addr[(AW-1):0]+1'b1));

		if ($past(mem_ce))
			`PHASE_ONE_ASSERT(op_Bid == $past(op_Bid));

		// `PHASE_ONE_ASSERT((op_Aid[3:1] != 3'h7)||(op_opn[0]));
		`PHASE_ONE_ASSERT((op_Bid[3:1] != 3'h7));
	end

	////////////////////////////////////////////////
	//
	// Assertions about the ALU stage
	//
	////////////////////////////////////////////////
	//
	//
	always @(*)
	if ((alu_ce)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT((op_valid_alu)&&(op_gie == gie));
	always @(*)
	if ((mem_ce)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT((op_valid_mem)&&(op_gie == gie));
	always @(*)
	if ((div_ce)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT((op_valid_div)&&(op_gie == gie));

	always @(*)
	if ((!clear_pipeline)&&((mem_valid)||(div_valid)||(div_busy)
					||(mem_rdbusy)||(alu_valid)))
		`PHASE_ONE_ASSERT(alu_gie == gie);
	always @(*)
	if ((!OPT_CIS)&&(alu_pc_valid))
		`PHASE_ONE_ASSERT(alu_pc[1:0] == 2'b0);
	always @(*)
	if (!OPT_LOCK)
		`PHASE_ONE_ASSERT((!bus_lock)&&(!prelock_stall));
	always @(*)
	if (!IMPLEMENT_DIVIDE)
		`PHASE_ONE_ASSERT((!div_busy)&&(!div_valid)&&(!div_ce));
	always @(*)
	if (IMPLEMENT_MPY == 0)
		`PHASE_ONE_ASSERT(alu_busy == 1'b0);


	always @(*)
	if (!clear_pipeline)
	begin
		if ((alu_valid)||(alu_illegal))
			`PHASE_ONE_ASSERT(alu_gie == gie);
		if (div_valid)
			`PHASE_ONE_ASSERT(alu_gie == gie);
	end

	always @(*)
	if (alu_busy)
	begin
		`PHASE_ONE_ASSERT(!mem_rdbusy);
		`PHASE_ONE_ASSERT(!div_busy);
		`PHASE_ONE_ASSERT(!fpu_busy);
	end else if (mem_rdbusy)
	begin
		`PHASE_ONE_ASSERT(!div_busy);
		`PHASE_ONE_ASSERT(!fpu_busy);
	end else if (div_busy)
		`PHASE_ONE_ASSERT(!fpu_busy);

	always @(posedge i_clk)
	if ((div_valid)||(div_busy))
		`PHASE_ONE_ASSERT(alu_reg[3:1] != 3'h7);

	always @(posedge i_clk)
	if ((f_past_valid)&&(wr_reg_ce)
			&&((!$past(r_halted))||(!$past(i_dbg_we))))
		`PHASE_ONE_ASSERT(alu_gie == gie);


	////////////////////////////////////////////////
	//
	// Assertions about the writeback stage
	//
	////////////////////////////////////////////////
	//
	//
	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_reset))&&($past(gie) != gie))
		`PHASE_ONE_ASSERT(clear_pipeline);

	always @(*)
	if (!IMPLEMENT_FPU)
	begin
		`PHASE_ONE_ASSERT((!dcd_valid)||(dcd_illegal)||(!dcd_FP));
		`PHASE_ONE_ASSERT(!op_valid_fpu);
		`PHASE_ONE_ASSERT((!fpu_valid)&&(!fpu_error));
		`PHASE_ONE_ASSERT(!ifpu_err_flag);
		`PHASE_ONE_ASSERT(!ufpu_err_flag);
	end else if (fpu_ce)
		`PHASE_ONE_ASSERT((!op_stall)&&(op_valid_fpu)&&(!op_illegal));

	always @(*)
	if (!IMPLEMENT_DIVIDE)
		`PHASE_ONE_ASSERT(!div_valid);

	always @(posedge i_clk)
	if ((f_past_valid)&&(r_halted))
	begin
		`PHASE_ONE_ASSERT(!div_busy);
		`PHASE_ONE_ASSERT(!mem_busy);
		`PHASE_ONE_ASSERT(!alu_busy);
		`PHASE_ONE_ASSERT(!div_valid);
		`PHASE_ONE_ASSERT(!mem_valid);
		`PHASE_ONE_ASSERT(!alu_valid);
	end

	/////////////////////
	// CONTRACT: Only one item can ever be valid at a time
	always @(posedge i_clk)
		if (alu_valid)
		begin
			`PHASE_ONE_ASSERT(!mem_valid);
			`PHASE_ONE_ASSERT(!div_valid);
			`PHASE_ONE_ASSERT(!fpu_valid);
		end else if (mem_valid)
		begin
			`PHASE_ONE_ASSERT(!div_valid);
			`PHASE_ONE_ASSERT(!fpu_valid);
		end else if (div_valid)
			`PHASE_ONE_ASSERT(!fpu_valid);

	always @(*)
	if (((wr_reg_ce)||(wr_flags_ce))&&(!dbgv))
		`PHASE_ONE_ASSERT(!alu_illegal);

	always @(*)
	if (wr_reg_ce)
	begin
		// Since writes are asynchronous, they can create errors later
		`PHASE_ONE_ASSERT((!bus_err)||(!mem_valid));
		`PHASE_ONE_ASSERT(!fpu_error);
		`PHASE_ONE_ASSERT(!div_error);
	end

	always @(*)
	if (wr_flags_ce)
	begin
		`PHASE_ONE_ASSERT((!bus_err)||(!mem_valid));
		`PHASE_ONE_ASSERT(!fpu_error);
		`PHASE_ONE_ASSERT(!div_error);
	end


	//////////////////////////////////////////////
	//
	//
	// Tying together the WB requests and acks
	//
	//
	//////////////////////////////////////////////
	//
	//
	always @(*)
	begin
		if (mem_cyc_gbl)
		begin
			`PHASE_ONE_ASSERT(f_gbl_mem_nreqs == f_mem_nreqs);
			`PHASE_ONE_ASSERT(f_gbl_mem_nacks == f_mem_nacks);
		end
		if (mem_cyc_lcl)
		begin
			`PHASE_ONE_ASSERT(f_lcl_mem_nreqs == f_mem_nreqs);
			`PHASE_ONE_ASSERT(f_lcl_mem_nacks == f_mem_nacks);
		end

		`PHASE_ONE_ASSERT(f_gbl_pf_nreqs == f_pf_nreqs);
		`PHASE_ONE_ASSERT(f_gbl_pf_nacks == f_pf_nreqs);
		`PHASE_ONE_ASSERT(f_gbl_pf_outstanding == f_pf_outstanding);

		`PHASE_ONE_ASSERT(f_lcl_pf_nreqs == 0);
		`PHASE_ONE_ASSERT(f_lcl_pf_nacks == 0);
	end

	//////////////////////////////////////////////
	// Ad-hoc phase-one assertions
	//////////////////////////////////////////////
	//

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&($past(mem_rdbusy))
			&&(!$past(mem_valid)||($past(mem_wreg[3:1] != 3'h7))))
		`PHASE_ONE_ASSERT(mem_wreg[4] == alu_gie);
	always @(posedge i_clk)
	if (mem_valid)
		`PHASE_ONE_ASSERT(mem_wreg[4] == alu_gie);


	always @(posedge i_clk)
	if ((op_valid_mem)&&(f_mem_pc))
		`PHASE_ONE_ASSERT(!op_pipe);

	always @(*)
		`PHASE_ONE_ASSERT(op_Aid == op_R);

	always @(*)
	if ((op_break)&&(!clear_pipeline))
		`PHASE_ONE_ASSERT(op_valid);

	// Break instructions are not allowed to move past the op stage
	always @(*)
	if ((break_pending)||(op_break))
		`PHASE_ONE_ASSERT((!alu_ce)&&(!mem_ce)&&(!div_ce)&&(!fpu_ce));

	always @(*)
	if (op_break)
		`PHASE_ONE_ASSERT((!alu_ce)&&(!mem_ce)&&(!div_ce)&&(!fpu_ce));

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))
			&&($past(break_pending))&&(!break_pending))
		`PHASE_ONE_ASSERT((clear_pipeline)||($past(clear_pipeline)));

	always @(*)
	if ((o_break)||((alu_valid)&&(alu_illegal)))
	begin
		`PHASE_ONE_ASSERT(!alu_ce);
		`PHASE_ONE_ASSERT(!mem_ce);
		`PHASE_ONE_ASSERT(!div_ce);
		`PHASE_ONE_ASSERT(!mem_rdbusy);
		// The following two shouldn't be true, but will be true
		// following a bus error
		`PHASE_ONE_ASSERT((bus_err)||(!div_busy));
		`PHASE_ONE_ASSERT((bus_err)||(!alu_busy));
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&(!$past(clear_pipeline))&&
			($past(div_busy))&&(!clear_pipeline))
	begin
		`PHASE_ONE_ASSERT($stable(alu_reg));
		`PHASE_ONE_ASSERT(alu_reg[4] == alu_gie);
		`PHASE_ONE_ASSERT($stable(alu_pc));
		`PHASE_ONE_ASSERT($stable(alu_phase));
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&(!i_reset)
			&&(!$past(clear_pipeline))&&(!clear_pipeline)
			&&(($past(div_busy))||($past(mem_rdbusy))))
		`PHASE_ONE_ASSERT($stable(alu_gie));

	always @(posedge i_clk)
	if (mem_rdbusy)
		`PHASE_ONE_ASSERT(!new_pc);

	always @(posedge i_clk)
		if ((wr_reg_ce)&&((wr_write_cc)||(wr_write_pc)))
			`PHASE_ONE_ASSERT(wr_spreg_vl == wr_gpreg_vl);

	always @(*)
	if ((dcd_phase)&&(dcd_valid)&&(!dcd_early_branch))
		`PHASE_ONE_ASSERT(f_dcd_hidden_state[31]);

	always @(posedge i_clk)
	if ((f_past_valid)&&(alu_gie)&&(wr_reg_ce)
			&&((!$past(r_halted))||(!$past(i_dbg_we))))
		`PHASE_ONE_ASSERT(wr_reg_id[4]);
	else if ((alu_gie)&&((alu_busy)||(div_busy)))
		`PHASE_ONE_ASSERT((!alu_wR)||(alu_reg[4]));

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(clear_pipeline))&&(!$past(i_reset))
		&&($past(op_valid))&&($past(op_illegal))&&(!op_illegal))
		`PHASE_ONE_ASSERT(alu_illegal);

	always @(*)
	if ((OPT_PIPELINED)&&(alu_valid)&&(alu_wR)&&(!clear_pipeline)
			&&(alu_reg[3:1] == 3'h7)
			&&(alu_reg[4:0] != { gie, `CPU_PC_REG }))
		`PHASE_ONE_ASSERT(pending_sreg_write);

	always @(*)
	if ((OPT_PIPELINED)&&(mem_valid)&&(mem_wreg[3:1] == 3'h7)
			&&(mem_wreg[4:0] != { gie, `CPU_PC_REG }))
		`PHASE_ONE_ASSERT(pending_sreg_write);
	else if ((OPT_PIPELINED)&&(OPT_LGDCACHE>0)&&(mem_wreg[3:1] == 3'h7)
			&&(mem_wreg[4:0] != { gie, `CPU_PC_REG })&&(mem_rdbusy))
		`PHASE_ONE_ASSERT(pending_sreg_write);

	always @(*)
	if (div_valid)
	begin
		`PHASE_ONE_ASSERT(!pending_sreg_write);
		`PHASE_ONE_ASSERT(alu_reg[3:1] != 3'h7);
	end

	always @(*)
	if ((OPT_PIPELINED)&&(mem_rdbusy))
	begin
		if (pending_sreg_write)
				assert(f_mem_pc);
		// `PHASE_ONE_ASSERT(pending_sreg_write == f_mem_pc);
	end

	always @(*)
	if ((op_valid_alu)||(op_valid_div)||(op_valid_mem)||(op_valid_fpu))
		`PHASE_ONE_ASSERT(op_valid);

	always @(*)
	if (!OPT_PIPELINED)
	begin
		if (op_valid)
		begin
			`PHASE_ONE_ASSERT(!dcd_valid);
			`PHASE_ONE_ASSERT(!mem_busy);
			`PHASE_ONE_ASSERT(!alu_busy);
			`PHASE_ONE_ASSERT(!div_busy);
			`PHASE_ONE_ASSERT((!wr_reg_ce)||(dbgv));
			`PHASE_ONE_ASSERT(!wr_flags_ce);
		end
	end

	always @(posedge i_clk)
	if ((!OPT_PIPELINED)&&(f_past_valid)&&(op_valid))
	begin
		if ((op_valid)||(alu_valid)||(mem_valid))
		begin
			`PHASE_ONE_ASSERT($stable(dcd_wR));
			`PHASE_ONE_ASSERT($stable(dcd_R));
			`PHASE_ONE_ASSERT($stable(dcd_A));
			`PHASE_ONE_ASSERT($stable(dcd_B));
			`PHASE_ONE_ASSERT($stable(dcd_rA));
			`PHASE_ONE_ASSERT($stable(dcd_rB));
			`PHASE_ONE_ASSERT($stable(dcd_pc));
		end
	end

	always @(posedge i_clk)
	if ((!OPT_PIPELINED)&&(f_past_valid)&&(dcd_valid))
	begin
		`PHASE_ONE_ASSERT((clear_pipeline)||(dcd_valid)||(op_valid));
	end
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
////                                                                       ////
////                                                                       ////
////  Formal proof, phase two                                              ////
////                                                                       ////
////  Once we've proved the properties contained in the first half of the  ////
////  proof (above), we can then turn to the second half where we willl    ////
////  assume those properties are true and attempt to prove some more      ////
////  complex properties                                                   ////
////                                                                       ////
////                                                                       ////
///////////////////////////////////////////////////////////////////////////////
///////////////////////////////////////////////////////////////////////////////
`ifdef	PHASE_TWO
	//
	// At this point, we've passed all of the phase one
	// assertions above in one round of formal.  We are now
	// entering our second round of formal.  Since we have
	// proven the assertions above are valid, we no longer
	// need to prove them again.  Hence we'll now assume them
	// and attempt to prove the following further assertions.
	//
	////////////////////////////////////////////////////////////////
	//
	//
	// Instruction Invariants section
	//
	//
	////////////////////////////////////////////////////////////////
	wire	[31:0]		f_const_insn;
	wire	[(AW+1):0]	f_const_addr, f_next_addr;
	wire			f_const_phase, f_const_gie, f_const_illegal;
	wire			f_pf_insn;

	assign	f_const_insn    = $anyconst;
	assign	f_const_addr    = $anyconst;
	assign	f_const_phase   = $anyconst;
	assign	f_const_illegal = $anyconst;
	assign	f_const_gie     = $anyconst;

	assign	f_pf_insn = (pf_valid)
		&&(pf_instruction_pc[(AW+1):2] == f_const_addr[(AW+1):2]);

	always @(*)
	if (f_pf_insn)
		restrict((pf_instruction == f_const_insn)
				&&(pf_illegal == f_const_illegal));

	always @(*)
	if (!f_const_insn[31])
	begin
		restrict(f_const_addr[1:0] == 2'b00);
		restrict(f_const_phase == 1'b0);
	end else begin
		restrict(f_const_phase == f_const_addr[1]);
		restrict(f_const_addr[0] == 1'b0);
	end


	wire	fc_illegal, fc_wF, fc_ALU, fc_M, fc_DV, fc_FP, fc_break,
			fc_lock, fc_wR, fc_rA, fc_rB, fc_sim;
	wire	[6:0]	fc_Rid, fc_Aid, fc_Bid;
	wire	[31:0]	fc_I;
	wire	[3:0]	fc_cond;
	wire	[3:0]	fc_op;
	wire	[22:0]	fc_sim_immv;
	wire		f_pre_dcd_insn, f_dcd_insn, f_op_insn; //f_alu_insn,f_wb_insn

	f_idecode #(.ADDRESS_WIDTH(AW),
		.OPT_MPY((IMPLEMENT_MPY!=0)? 1'b1:1'b0),
		.OPT_EARLY_BRANCHING(EARLY_BRANCHING),
		.OPT_DIVIDE(IMPLEMENT_DIVIDE),
		.OPT_FPU(IMPLEMENT_FPU),
		.OPT_LOCK(OPT_LOCK),
		.OPT_OPIPE(OPT_PIPELINED_BUS_ACCESS),
		.OPT_SIM(1'b0),
		.OPT_CIS(OPT_CIS))
		f_insn_decode(f_const_insn, f_const_phase, f_const_gie,
			fc_illegal, fc_Rid, fc_Aid, fc_Bid, fc_I, fc_cond,
			fc_wF, fc_op, fc_ALU, fc_M, fc_DV, fc_FP,
			fc_break, fc_lock, fc_wR, fc_rA, fc_rB,
			fc_sim, fc_sim_immv
			);

	assign	f_next_addr = ((!f_const_insn[31])||(!f_const_phase))
				? (f_const_addr + 4)
				: (f_const_addr + 2);

	assign	f_dcd_insn = (dcd_valid)&&(dcd_pc == f_next_addr)
				&&(dcd_phase == f_const_phase)
				&&(dcd_gie == f_const_gie);

	assign	f_pre_dcd_insn = (dcd_valid)&&(dcd_phase)&&(!f_const_phase)
			&&(dcd_pc == f_const_addr + 2)
				&&(dcd_gie == f_const_gie);

	assign	f_op_insn = (op_valid)&&(op_pc == f_next_addr)
				&&(op_phase == f_const_phase)
				&&(op_gie == f_const_gie)
				&&(!f_op_branch);

	wire	[31:0]	f_Av, f_Bv, f_pre_Bv;

	//
	//
	// The A operand
	//
	//
	always @(*)
	begin
		f_Av = regset[fc_Aid[4:0]];
		if (fc_Aid[3:0] == `CPU_PC_REG)
		begin
			if ((wr_reg_ce)&&(wr_reg_id == fc_Aid[4:0]))
				f_Av = wr_spreg_vl;
			else if (fc_Aid[4] == f_const_gie )
				f_Av = f_next_addr;
			else if (fc_Aid[3:0] == { 1'b1, `CPU_PC_REG })
			begin
				f_Av[31:(AW+1)] = 0;
				f_Av[(AW+1):0] = { upc, uhalt_phase, 1'b0 };
			end
		end else if (fc_Aid[4:0] == { 1'b0, `CPU_CC_REG })
		begin
			f_Av = { w_cpu_info, regset[fc_Aid[4:0]][22:16], 1'b0, w_iflags };
			if ((wr_reg_ce)&&(wr_reg_id == fc_Aid[4:0]))
				f_Av[22:16] = wr_spreg_vl[22:16];
		end else if (fc_Aid[4:0] == { 1'b1, `CPU_CC_REG })
		begin
			f_Av = { w_cpu_info, regset[fc_Aid[4:0]][22:16], 1'b1, w_uflags };
			if ((wr_reg_ce)&&(wr_reg_id == fc_Aid[4:0]))
				f_Av[22:16] = wr_spreg_vl[22:16];
		end else if ((wr_reg_ce)&&(wr_reg_id == fc_Aid[4:0]))
			f_Av = wr_gpreg_vl;
		else
			f_Av = regset[fc_Aid[4:0]];
	end

	//
	//
	// The B operand
	//
	//

	// The PRE-logic
	always @(*)
	begin
		f_pre_Bv = regset[fc_Bid[4:0]];
		//
		if (fc_Bid[3:0] == `CPU_PC_REG)
		begin
			// Can always read your own address
			if (fc_Bid[4] == f_const_gie)
				f_pre_Bv = f_next_addr;
			else // if (fc_Bid[4])
				// Supervisor or user may read the users PC reg
			begin
				f_pre_Bv = 0;
				f_pre_Bv[(AW+1):0] = { upc[(AW+1):2], uhalt_phase, 1'b0 };
				if ((wr_reg_ce)&&(wr_reg_id == fc_Bid[4:0]))
					f_pre_Bv = wr_spreg_vl;
			end
		end else if (fc_Bid[3:0] == `CPU_CC_REG)
		begin
			f_pre_Bv = { w_cpu_info, regset[fc_Bid[4:0]][22:16], 1'b0,
					w_uflags };
			if ((fc_Bid[4] == f_const_gie)&&(!fc_Bid[4]))
				f_pre_Bv[14:0] = (f_const_gie) ? w_uflags : w_iflags;

			if ((wr_reg_ce)&&(wr_reg_id == fc_Bid[4:0]))
				f_pre_Bv[22:16] = wr_spreg_vl[22:16];

		end else if ((wr_reg_ce)&&(wr_reg_id == fc_Bid[4:0]))
			f_pre_Bv = wr_gpreg_vl;
		else
			f_pre_Bv = regset[fc_Bid[4:0]];
	end


	// The actual calculation of B
	assign	f_Bv = (fc_rB)
			? ((fc_Bid[5])
				? ( { f_pre_Bv }+{ fc_I[29:0],2'b00 })
				: (f_pre_Bv + fc_I))
			: fc_I;

	////////////////////////////////////////////////////////////////
	//
	//
	// Pipeline signaling check
	//
	//
	////////////////////////////////////////////////////////////////
	//
	//

	//
	// Assertions about the prefetch
	// Assertions about the decode stage
	// dcd_ce, dcd_valid
	wire	[1+4+15+6+4+13+AW+1+32+4+23-1:0]	f_dcd_data;
	assign	f_dcd_data = {
			dcd_phase,
			dcd_opn, dcd_A, dcd_B, dcd_R,	// 4+15
			dcd_Acc, dcd_Bcc, dcd_Apc, dcd_Bpc, dcd_Rcc, dcd_Rpc,//6
			dcd_F,		// 4
			dcd_wR, dcd_rA, dcd_rB,
				dcd_ALU, dcd_M, dcd_DIV, dcd_FP,
				dcd_wF, dcd_gie, dcd_break, dcd_lock,
				dcd_pipe, dcd_ljmp,
			dcd_pc, 	// AW+1
			dcd_I,		// 32
			dcd_zI,	// true if dcd_I == 0
			dcd_illegal,
			dcd_early_branch,
			dcd_sim, dcd_sim_immv
		};

	////////////////////////////////////////////////
	//
	// Assertions about the prefetch (output) stage
	//
	////////////////////////////////////////////////

	////////////////////////////////////////////////
	//
	// Assertions about the decode stage
	//
	////////////////////////////////////////////////

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&(!$past(clear_pipeline))
			&&(!$past(w_clear_icache))
			&&($past(dcd_valid))&&($past(dcd_stalled))
			&&(!clear_pipeline))
	begin
		`PHASE_TWO_ASSERT((!OPT_PIPELINED)||(dcd_valid));
		`PHASE_TWO_ASSERT(f_dcd_data == $past(f_dcd_data));
	end

	always @(*)
	if ((dcd_valid)&&(!dcd_early_branch)&&(!dcd_ljmp)
			&&(f_const_addr[(AW+1):2] == dcd_pc[(AW+1):2])
			&&(!f_const_insn[31])
			&&(!f_const_phase))
		`PHASE_TWO_ASSERT(!dcd_pc[1]);

	always @(*)
	if ((f_pre_dcd_insn)&&(!clear_pipeline))
		`PHASE_TWO_ASSERT(dcd_illegal == f_const_illegal);

	always @(*)
	if ((f_dcd_insn)&&(!clear_pipeline))
	begin
		if ((fc_illegal)||(f_const_illegal))
			`PHASE_TWO_ASSERT(dcd_illegal);
		else begin
			`PHASE_TWO_ASSERT(!dcd_illegal);
			`PHASE_TWO_ASSERT(fc_Rid[6:0] == { dcd_Rcc, dcd_Rpc, dcd_R });
			`PHASE_TWO_ASSERT(fc_Aid[6:0] == { dcd_Acc, dcd_Apc, dcd_A });
			`PHASE_TWO_ASSERT(fc_Bid[6:0] == { dcd_Bcc, dcd_Bpc, dcd_B });
			`PHASE_TWO_ASSERT(fc_cond == dcd_F);
			`PHASE_TWO_ASSERT(fc_ALU == dcd_ALU);
			`PHASE_TWO_ASSERT(fc_DV  == dcd_DIV);
			`PHASE_TWO_ASSERT(fc_M   == dcd_M);
			`PHASE_TWO_ASSERT(fc_op  == dcd_opn);
			`PHASE_TWO_ASSERT(fc_wR  == dcd_wR);
			`PHASE_TWO_ASSERT(fc_wF  == dcd_wF);
			`PHASE_TWO_ASSERT(fc_rA  == dcd_rA);
			`PHASE_TWO_ASSERT(fc_rB  == dcd_rB);
			`PHASE_TWO_ASSERT(fc_I   == dcd_I);
			`PHASE_TWO_ASSERT(fc_lock== dcd_lock);
			`PHASE_TWO_ASSERT(dcd_zI == (dcd_I==0));
			`PHASE_TWO_ASSERT(dcd_break == fc_break);
			`PHASE_TWO_ASSERT((f_dcd_hidden_state[31])||(!dcd_phase));
			`PHASE_TWO_ASSERT((f_dcd_hidden_state[31])||(dcd_pc[1:0]==2'b00));
		end
	end


	always @(*)
	if ((OPT_CIS)&&(f_const_insn[31])&&(dcd_pc == f_next_addr)&&(dcd_valid)
		&&(!clear_pipeline))
	begin
		// The following instructions are not valid
		// compressed instructions
		`PHASE_TWO_ASSERT(!dcd_DIV);
		`PHASE_TWO_ASSERT(!dcd_FP);
		`PHASE_TWO_ASSERT(!dcd_break);
		`PHASE_TWO_ASSERT(dcd_R[4] == dcd_gie);
		`PHASE_TWO_ASSERT(dcd_A[4] == dcd_gie);
		`PHASE_TWO_ASSERT(dcd_B[4] == dcd_gie);
		if (dcd_M) // Only LW and SW mem ops allowed
			`PHASE_TWO_ASSERT(dcd_opn[2:1] == 2'b01);
	end

	always @(*)
	if ((OPT_CIS)&&(f_const_insn[31])&&(dcd_valid)&&(!dcd_phase)
		&&(dcd_pc == f_next_addr))
	begin
		`PHASE_TWO_ASSERT(!dcd_DIV);
		if (dcd_ALU)
		begin
			`PHASE_TWO_ASSERT(dcd_opn != 4'h3);
			`PHASE_TWO_ASSERT(dcd_opn != 4'h4);
			`PHASE_TWO_ASSERT(dcd_opn != 4'h5);
			`PHASE_TWO_ASSERT(dcd_opn != 4'h6);
			`PHASE_TWO_ASSERT(dcd_opn != 4'h7);
			`PHASE_TWO_ASSERT(dcd_opn != 4'h8);
			`PHASE_TWO_ASSERT(dcd_opn != 4'h9);
			`PHASE_TWO_ASSERT(dcd_opn != 4'ha);
			`PHASE_TWO_ASSERT(dcd_opn != 4'hb);
			`PHASE_TWO_ASSERT(dcd_opn != 4'hc);
		end
		if (dcd_M) // Only LW and SW mem ops allowed
			`PHASE_TWO_ASSERT(dcd_opn[2:1] == 2'b01);
	end

	always @(*)
	if ((dcd_valid)&&(!dcd_illegal)&&(dcd_ALU))
	begin
		`PHASE_TWO_ASSERT(dcd_opn < 4'he);
	end

	////////////////////////////////////////////////
	//
	// Assertions about the op stage
	//
	////////////////////////////////////////////////
	// op_valid
	// op_ce
	// op_stall
	wire	[4+AW+2+7+4-1:0]	f_op_data;
	assign	f_op_data = { op_valid_mem, op_valid_alu,
			op_valid_div, op_valid_fpu,
		// The Av and Bv values can change while we are stalled in the
		// op stage--that's why we are stalled there
		//	r_op_Av, r_op_Bv,	// 32 ea
			op_pc[AW+1:2],		// AW
			op_wR, op_wF,
			r_op_F,			// 7
			op_illegal, op_break,
			op_lock, op_pipe
			};


	reg	f_op_branch;
	initial	f_op_branch = 1'b0;
	always @(posedge i_clk)
	if ((i_reset)||(clear_pipeline))
		f_op_branch <= 1'b0;
	else if (op_ce)
		f_op_branch <= (dcd_early_branch)||dcd_ljmp;
	else if ((adf_ce_unconditional)||(mem_ce))
		f_op_branch <= 1'b0;

	always @(posedge i_clk)
		if ((f_past_valid)&&($past(op_valid))&&(!$past(i_reset))
				&&(!$past(clear_pipeline)))
		begin
			if (($past(op_valid_mem))&&($past(mem_stalled)))
				`PHASE_TWO_ASSERT($stable(f_op_data[AW+16:1])&&(!$rose(op_pipe)));
	/*
			if (($past(op_valid_alu))&&($past(alu_stall)))
			begin
				if ((!$past(op_break))&&(!$past(op_illegal)))
////// HUH??
					assert($stable(f_op_data));
			end
	*/
			if (($past(op_valid_div))&&($past(div_busy)))
				`PHASE_TWO_ASSERT($stable(f_op_data));
		end

	////////////////////////////////
	//
	// CONTRACT: The operands to an ALU/MEM/DIV operation
	//   must be valid.
	//
	always @(posedge i_clk)
	if ((f_op_insn)&&(!f_const_illegal)&&(!fc_illegal)&&(!clear_pipeline))
	begin
		if (((!wr_reg_ce)||(wr_reg_id!= { gie, `CPU_PC_REG }))
			&&(!dbg_clear_pipe)&&(!clear_pipeline))
		begin
			if ((fc_rA)&&(fc_Aid[3:1] != 3'h7))
				`PHASE_TWO_ASSERT(f_Av == op_Av);
			`PHASE_TWO_ASSERT(f_Bv == op_Bv);
		end
	end

	always @(posedge i_clk)
	if ((f_op_insn)&&(!f_const_illegal)&&(!fc_illegal)&&(!clear_pipeline))
	begin
		`PHASE_TWO_ASSERT(op_valid);
		`PHASE_TWO_ASSERT(fc_wR == op_wR);
		`PHASE_TWO_ASSERT(fc_rA == op_rA);
		`PHASE_TWO_ASSERT(fc_rB == op_rB);
		`PHASE_TWO_ASSERT((!fc_rB)||(fc_Bid[4:0] == op_Bid));
		`PHASE_TWO_ASSERT(fc_wF == op_wF);
		`PHASE_TWO_ASSERT(fc_Rid[4:0] == op_R);
		`PHASE_TWO_ASSERT(fc_DV  == op_valid_div);
		`PHASE_TWO_ASSERT(fc_ALU == op_valid_alu);
		if ((!alu_illegal)&&(!ill_err_i)&&(!clear_pipeline))
		begin
			`PHASE_TWO_ASSERT(fc_M   == op_valid_mem);
			`PHASE_TWO_ASSERT(fc_op  == op_opn);
		end
		`PHASE_TWO_ASSERT(fc_break == op_break);
		`PHASE_TWO_ASSERT(fc_lock == op_lock);
		`PHASE_TWO_ASSERT(f_op_zI == (fc_I == 0));
		`PHASE_TWO_ASSERT((!wr_reg_ce)||(wr_reg_id != fc_Bid)
				||(!fc_rB)||(fc_I == 0));
		if (!OPT_PIPELINED_BUS_ACCESS)
			`PHASE_TWO_ASSERT((!mem_rdbusy)||(mem_wreg != fc_Bid)
				||(!fc_rB)||(fc_I == 0));
	end else if ((f_op_insn)&&(!clear_pipeline))
		`PHASE_TWO_ASSERT(op_illegal);


	/////////
	//
	// CIS instructions, enabled by OPT_CIS
	//
	/////////

	// If we are on the second half of a compressed instruction,
	// then there are some criteria regarding what operations are possible.
	always @(*)
	if ((OPT_CIS)&&(f_const_insn[31])&&(op_pc == f_next_addr)
		&&(op_valid)&&(!f_op_branch)&&(!clear_pipeline))
	begin
		// The following instructions are not valid
		// compressed instructions
		`PHASE_TWO_ASSERT(!op_valid_div);
		`PHASE_TWO_ASSERT(!op_valid_fpu);
		`PHASE_TWO_ASSERT(!op_break);
		`PHASE_TWO_ASSERT((!op_wR)||(op_R[4]   == op_gie));
		`PHASE_TWO_ASSERT((!op_rA)||(op_Aid[4] == op_gie));
		`PHASE_TWO_ASSERT((!op_rB)||(op_Bid[4] == op_gie));
	end

	always @(*)
	if ((OPT_CIS)&&(f_const_insn[31])&&(op_valid)&&(op_pc == f_next_addr))
	begin
		`PHASE_TWO_ASSERT(!op_valid_div);
		if ((op_valid_alu)&&(!op_illegal))
		begin
			`PHASE_TWO_ASSERT(op_opn != 4'h3);
			`PHASE_TWO_ASSERT(op_opn != 4'h4);
			`PHASE_TWO_ASSERT(op_opn != 4'h5);
			`PHASE_TWO_ASSERT(op_opn != 4'h6);
			`PHASE_TWO_ASSERT(op_opn != 4'h7);
			`PHASE_TWO_ASSERT(op_opn != 4'h8);
			`PHASE_TWO_ASSERT(op_opn != 4'h9);
			`PHASE_TWO_ASSERT(op_opn != 4'ha);
			`PHASE_TWO_ASSERT(op_opn != 4'hb);
			`PHASE_TWO_ASSERT(op_opn != 4'hc);
		end
	end


	// If the item going through the isn't an instruction, but rather the
	// shell of an instruction following an early branch, then none of
	// the various valid's shall be true.  It will instead be implemnted
	// as an empty instruction that neither reads operands nor writes
	// a result back.
	always @(*)
	if ((f_op_branch)&&(op_valid))
	begin
		`PHASE_TWO_ASSERT(!op_valid_alu);
		`PHASE_TWO_ASSERT(!op_valid_mem);
		`PHASE_TWO_ASSERT(!op_valid_div);
		`PHASE_TWO_ASSERT(!op_valid_fpu);
		`PHASE_TWO_ASSERT(!op_illegal);
		`PHASE_TWO_ASSERT(!op_rA);
		`PHASE_TWO_ASSERT(!op_rB);
		`PHASE_TWO_ASSERT(!op_wR);
		`PHASE_TWO_ASSERT(op_opn == `CPU_MOV_OP);
	end


	////////////////////////////////////////////////
	//
	// Assertions about the ALU stage
	//
	////////////////////////////////////////////////
	//
	//
	// alu_valid
	// alu_ce
	// alu_stall
	// ALU stage assertions

	reg	f_alu_branch;
	initial	f_alu_branch = 1'b0;
	always @(posedge i_clk)
	if ((adf_ce_unconditional)||(mem_ce))
		f_alu_branch <= f_op_branch;

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))
		&&(f_const_insn[31])&&(alu_pc == f_next_addr))
	begin
		`PHASE_TWO_ASSERT(!div_busy);
		`PHASE_TWO_ASSERT(!alu_busy);
		`PHASE_TWO_ASSERT(!div_valid);
	end

	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))
		&&(div_busy)&&(alu_pc == f_next_addr)&&(alu_gie == f_const_gie)
		&&(!clear_pipeline))
	begin
		`PHASE_TWO_ASSERT(fc_Rid == alu_reg);
	end

	////////////////////////////////////////////////
	//
	// Assertions about the writeback stage
	//
	////////////////////////////////////////////////
	//
	//
	// From user mode, the user is not allowed to write
	// to a supervisor register
	//
	//
	//
	// See that we handle illegal instructions properly
	always @(posedge i_clk)
	if((dcd_valid)&&(dcd_phase)&&(dcd_pc[(AW+1):2]==f_const_addr[(AW+1):2]))
	begin
		if (f_const_illegal)
			`PHASE_TWO_ASSERT(dcd_illegal);

		`PHASE_TWO_ASSERT(f_dcd_hidden_state[31:16]
			== {1'b1, f_const_insn[14:0]});
	end

	//////////////////////////////////////////////
	//
	//
	// Writeback properties
	//
	//
	//////////////////////////////////////////////
	always @(posedge i_clk)
	if ((alu_pc_valid)&&(alu_pc == f_next_addr)
			&&(!f_alu_branch)
			&&(!r_halted)
			&&(alu_gie == f_const_gie)
			&&(alu_phase == f_const_phase)
			&&(!clear_pipeline))
	begin
		if (!fc_DV)
			`PHASE_TWO_ASSERT(!div_busy);
		if (!fc_wR)
			`PHASE_TWO_ASSERT(!wr_reg_ce);
		if (wr_reg_ce)
			`PHASE_TWO_ASSERT(wr_reg_id == fc_Rid[4:0]);
		if (wr_flags_ce)
			`PHASE_TWO_ASSERT(fc_wF);
// Not true.  mem_pc_valid is true when the memory op is issued, not when
// it is completed
//	end else if ((!alu_pc_valid)&&(!mem_pc_valid)&&(!alu_phase))
//	begin
//		assert((!wr_reg_ce)||(!f_past_valid)||($past(i_dbg_we)));
//		assert(!wr_flags_ce);
	end

	initial	assert((!OPT_LOCK)||(OPT_PIPELINED));

	//////////////////////////////////////////////
	//
	//
	// Ad-hoc (unsorted) properties
	//
	//
	//////////////////////////////////////////////
	always @(posedge i_clk)
	if ((alu_ce)||(div_ce))
		`PHASE_TWO_ASSERT(adf_ce_unconditional);

	always @(posedge i_clk)
	if ((!clear_pipeline)&&(master_ce)&&(op_ce)&&(op_valid))
	begin
		if (op_valid_mem)
			`PHASE_TWO_ASSERT((mem_ce)||(!set_cond));
		else begin
			`PHASE_TWO_ASSERT(!master_stall);
			if ((set_cond)&&(op_valid_div))
				`PHASE_TWO_ASSERT(div_ce||pending_sreg_write);
			if (!op_valid_alu)
				assert(!alu_ce);
		end
	end

	//////////////////////////////////////////////
	//
	//
	// Cover statements
	//
	//
	//////////////////////////////////////////////
	wire	w_switch_to_interrupt, w_release_from_interrupt;
	always @(posedge i_clk)
	if ((gie)&&(wr_reg_ce))
	begin
		// Cover the switch to interrupt
		cover((i_interrupt)&&(!alu_phase)&&(!bus_lock));

		// Cover a "step" instruction
		cover(((alu_pc_valid)||(mem_pc_valid))
				&&(step)&&(!alu_phase)&&(!bus_lock));

		// Cover a break instruction
		cover((master_ce)&&(break_pending)&&(!break_en));

		// Cover an illegal instruction
		cover((alu_illegal)&&(!clear_pipeline));

		// Cover a division by zero
		cover(div_error);

		// Cover a bus error
		cover(bus_err);

		// Cover a TRAP instruction to the CC register
		cover(((wr_reg_ce)&&(!wr_spreg_vl[`CPU_GIE_BIT])
				&&(wr_reg_id[4])&&(wr_write_cc)));
	end

	//////////////////////////////////////////////
	//////////////////////////////////////////////
	//
//	always @(*)
//	if (break_pending)
//		`PHASE_TWO_ASSERT((op_valid)&&(op_break));
	//////////////////////////////////////////////
	//
	//
	// Problem limiting assumptions
	//
	//
	//////////////////////////////////////////////
	//
	// Careless assumptions might be located here

	always @(*)
		assume(fc_Aid[3:0] != `CPU_CC_REG);
	always @(*)
		assume(fc_Bid[3:0] != `CPU_CC_REG);

	always @(*)
		assume(!i_halt);
`endif	// PHASE_ONE

`endif	// FORMAL
	//}}}

endmodule
