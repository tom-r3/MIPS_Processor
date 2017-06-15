typedef enum { sz_byte, sz_word, sz_4word, sz_8word } mem_access_sizes;

module mips(
	// port list
	input clk, reset,
    output [31:0] instr_addr,
    input [31:0] instr_in,
    output [31:0] data_addr,
    input [31:0] data_in,
    output logic [31:0] data_out,
    output logic [1:0] data_access_size,
    output data_rd_wr);

	// parameters overridden in testbench
	parameter [31:0] pc_init = 0;
	parameter [31:0] sp_init = 0;
	parameter [31:0] ra_init = 0;

	// IF signals
	logic [31:0] pc, pc_4, pc_8;
	assign instr_addr = pc;
	logic [31:0] ir;

	logic [5:0] opcode, func;
	logic [4:0] rs, rt, rd, shift_amt;
	logic [15:0] imm;
	logic [25:0] target;
	assign opcode = ir[31:26];
	assign rs = ir[25:21];
	assign rt = ir[20:16];
	assign rd = ir[15:11];
	assign shift_amt = ir[10:6];
	assign func = ir[5:0];
	assign imm = ir[15:0];
	assign target = ir[25:0];

	// ID signals
    logic [4:0] reg_rd_num0, reg_rd_num1;
    wire [31:0] reg_rd_data0, reg_rd_data1, rs_data, rt_data;
	assign reg_rd_num0 = ir[25:21];
	assign reg_rd_num1 = ir[20:16];
	assign rs_data = reg_rd_data0;
	assign rt_data = reg_rd_data1;

	// EX signals
	logic set;
	logic [31:0] a, b, sign_ext_imm, alu_out, add, sub, shift, upper_imm, ext_data_in, zero;
	logic [63:0] mult;
	logic alu_src_a, alu_src_b;
	logic [1:0] alu_op;
	assign sign_ext_imm = {{16{ir[15]}},ir[15:0]};
	assign upper_imm = imm << 16;
	assign ext_data_in = {24'b0, data_in[7:0]};

	// ME signals
	logic st_en;
	assign data_out = rt_data;
	assign data_rd_wr = ~st_en;
	logic mem_wr;
	logic [2:0] mem_to_reg;
 	assign data_addr = alu_out;
	assign st_en = (mem_wr && (state == me)) ? 1 : 0;

	// WD signals
    logic [4:0] reg_wr_num;
    logic [31:0] reg_wr_data;
    logic reg_wr_en, reg_wr;
    logic [1:0] reg_dst;
    assign reg_wr = (reg_wr_en && (state==me || state==wb)) ? 1 : 0;

    // PC control signals
    logic [1:0] pc_src;
    logic [31:0] jump_target, branch_target, next_pc;	
    assign jump_target = {pc_4[31:28], target, 2'b00};
    assign branch_target = pc_4 + {{14{ir[15]}}, imm, 2'b0};

	enum { init, fetch, id, ex, me, wb } state;

	// register file
    regfile #(.sp_init(sp_init), .ra_init(ra_init)) regs(
		.wr_num(reg_wr_num), .wr_data(reg_wr_data), .wr_en(reg_wr),
        .rd0_num(reg_rd_num0), .rd0_data(reg_rd_data0),
		.rd1_num(reg_rd_num1), .rd1_data(reg_rd_data1),
        .clk(clk), .reset(reset));

	//mem_to_reg multiplexer
	assign reg_wr_data = (mem_to_reg==0) ? alu_out : (mem_to_reg==1) ? data_in : (mem_to_reg==2) ? set : (mem_to_reg==3) ? pc_8 : (mem_to_reg==4) ? upper_imm : ext_data_in;

	//alu_src multiplexers and "a" wire
	assign a = (alu_src_a) ? shift_amt : rs_data;
	assign b = (alu_src_b) ? rt_data : sign_ext_imm;

	//reg_dst multiplexer
	assign reg_wr_num = (reg_dst==0) ? rt : (reg_dst==1) ? rd : 31;

	//pc_src multiplexer
	assign next_pc = (pc_src==0) ? pc_4 : (pc_src==1) ? jump_target : (pc_src==2) ? rs_data : branch_target;

	//alu_op options
	assign add = a + b;
	assign sub = a - b;
	assign mult = a * b;
	assign shift = b << a;

	always @(posedge clk or posedge reset) begin
		if(reset) begin
			reg_wr_en <= 0;
			pc <= pc_init;
			state <= init;
		end
		else
			case(state)
				init: begin
					// this state is needed since we have to wait for
					// memory to produce the first instruction after reset
					state <= fetch;
				end
				fetch: begin
					ir <= instr_in;
					pc_4 = pc + 4;
					pc_8 = pc + 8;
					pc_src <= 0;
					mem_wr <= 0;
					reg_wr_en <= 0;
					data_access_size <= sz_word;

					state <= id;
				end
				id: begin
					//control logic
					case(opcode)
						6'b000000: begin //special
							case(func)
								6'b000000: begin //sll and nop
									reg_dst <= 1; //rd
									mem_to_reg <= 0; //alu_out
									reg_wr_en <= 1;
									alu_src_a <= 1; //shift_amt
									alu_src_b <= 1; //rt_data
									alu_op <= 3; //shift
								end
								6'b100001: begin //addu
									alu_op <= 1;
									mem_to_reg <= 0; //alu_out
									alu_src_a <= 0; //rs_data
									alu_src_b <= 1; //rt_data
									reg_wr_en <= 1;
									reg_dst <= 1; //rd or ir[15:11]
								end
								6'b100011: begin //subu
									alu_op <= 0;
									mem_to_reg <= 0; //alu_out
									alu_src_a <= 0; //rs_data
									alu_src_b <= 1; //rt_data
									reg_wr_en <= 1;
									reg_dst <= 1; //rd
								end
								6'b001000: begin //jump register
									pc_src <= 2; //rs_data
								end
							endcase
						end
						6'b011100: begin //special 2
							case(func)
								6'b000010: begin //mul
									alu_src_a <= 0; //rs_data
									alu_src_b <= 1; //rt_data
									alu_op <= 2; //mult
									reg_wr_en <= 1;
									reg_dst <= 1; //rd
									mem_to_reg <= 0; //alu_out
								end
							endcase
						end
						6'b001001: begin //addiu, li
							alu_op <= 1;
							mem_to_reg <= 0; //alu_out
							alu_src_a <= 0; //rs_data
							alu_src_b <= 0; //sign_ext_imm
							reg_wr_en <= 1;
							reg_dst <= 0; //rt or ir[20:16]
						end
						6'b001111: begin //lui
							mem_to_reg <= 4; //upper_imm
							reg_dst <= 0; //rt
							reg_wr_en <= 1;
						end
						//sw and sb work because data_addr is assigned to always be alu_out
						6'b101011: begin //sw
							alu_src_a <= 0; //rs_data
							alu_src_b <= 0; //sign_ext_imm
							alu_op <= 1; //add
							mem_wr <= 1; //enable store to memory
						end
						6'b101000: begin //sb
							data_access_size <= sz_byte;
							alu_src_a <= 0; //rs_data
							alu_src_b <= 0; //sign_ext_imm
							alu_op <= 1; //add
							mem_wr <= 1; //enable store to memory
						end
						6'b100011: begin //lw
							alu_op <= 1; //add
							mem_to_reg <= 1; //data_in
							alu_src_a <= 0; //rs_data
							alu_src_b <= 0; //sign_ext_imm
							reg_wr_en <= 1; //write back enabled
							mem_wr <= 0; //enable read from memory
							reg_dst <= 0; //rt or ir[20:16]
						end
						6'b100100: begin //lbu
							data_access_size <= sz_byte;
							alu_op <= 1; //add
							alu_src_a <= 0; //rs_data
							alu_src_b <= 0; //sign_ext_imm
							reg_wr_en <= 1; //write back enabled
							mem_wr <= 0; //enable read from memory
							reg_dst <= 0; //rt
							mem_to_reg <= 5; //ext_data_in
						end
						6'b000010: begin //jump
							pc_src <= 1; //jump_target
						end
						6'b000011: begin //jump and link
							pc_src <= 1; //jump_target
							reg_wr_en <= 1;
							reg_dst <= 2; //31
							mem_to_reg <= 3; //pc_8
						end
						6'b001010: begin //slti
							reg_wr_en <= 1;
							mem_to_reg <= 2; //set
							set <= (rs_data < sign_ext_imm) ? 1 : 0;
							reg_dst <= 0; //rt
						end
						6'b000100: begin //beq
							pc_src <= (rs_data == rt_data) ? 3 : 0; //branch_target or pc_4
						end
						6'b000101: begin //bne
							pc_src <= (rs_data != rt_data) ? 3 : 0; //branch_target or pc_4
						end
					endcase

					state <= ex;
				end
				ex: begin
					alu_out = (alu_op==0) ? sub : (alu_op==1) ? add : (alu_op==2) ? mult : shift;

					state <= me;
				end
				me: begin
					pc <= next_pc;

					state <= wb;
				end
				wb: begin

					state <= fetch;
				end
				default: begin
					reg_wr_en <= 0;

					state <= fetch;
				end
			endcase
	end

endmodule
