// JTAG Debug Transport Module (RISC-V Debug spec 0.13.2, mien tck): TAP 16 trang thai, IR 5 bit (IDCODE 0x01, DTMCS 0x10,
// DMI 0x11, BYPASS 0x1F), dtmcs (version 1, abits 7, dmistat, dmireset, dmihardreset), DMI 41 bit (addr 7, data 32, op 2).
// Yeu cau DMI di sang mien clk qua bat tay doi trang thai (req_tog / resp_tog, dong bo 2 tang); khi do DTM bao "busy" (op = 3)
// neu quet tiep truoc khi co tra loi, giu cho toi khi dmireset.
module rv32_dtm #(
    parameter [31:0] IDCODE = 32'h1000_2001
) (
    input  wire        tck,
    input  wire        tms,
    input  wire        tdi,
    output reg         tdo,
    input  wire        trst_n,
    // DMI sang mien clk
    input  wire        clk,
    input  wire        rst_n,
    output wire        dmi_valid,
    output wire        dmi_write,
    output wire [6:0]  dmi_addr,
    output wire [31:0] dmi_wdata,
    input  wire [31:0] dmi_rdata
);
    localparam TLR = 4'd0, RTI = 4'd1, SDR = 4'd2, CDR = 4'd3, SHD = 4'd4, E1D = 4'd5, PAD = 4'd6, E2D = 4'd7, UPD = 4'd8,
               SIR = 4'd9, CIR = 4'd10, SHI = 4'd11, E1I = 4'd12, PAI = 4'd13, E2I = 4'd14, UPI = 4'd15;
    localparam [4:0] IR_IDCODE = 5'h01, IR_DTMCS = 5'h10, IR_DMI = 5'h11;

    reg [3:0]  st;
    reg [4:0]  ir, ir_sh;
    reg [40:0] dr;
    reg [1:0]  sticky;                 // dmistat: 0 ok, 2 loi, 3 busy
    reg [6:0]  last_addr;
    reg [31:0] last_data;
    reg [1:0]  last_op;
    reg        req_tog;
    reg [6:0]  req_addr;
    reg [31:0] req_data;
    reg        req_wr;
    reg        resp_tog_s1, resp_tog_s2;
    wire       resp_tog;
    wire [31:0] resp_data;
    wire       busy = (req_tog != resp_tog_s2);

    wire [3:0] nxt = (st == TLR) ? (tms ? TLR : RTI) : (st == RTI) ? (tms ? SDR : RTI) : (st == SDR) ? (tms ? SIR : CDR) :
                     (st == CDR) ? (tms ? E1D : SHD) : (st == SHD) ? (tms ? E1D : SHD) : (st == E1D) ? (tms ? UPD : PAD) :
                     (st == PAD) ? (tms ? E2D : PAD) : (st == E2D) ? (tms ? UPD : SHD) : (st == UPD) ? (tms ? SDR : RTI) :
                     (st == SIR) ? (tms ? TLR : CIR) : (st == CIR) ? (tms ? E1I : SHI) : (st == SHI) ? (tms ? E1I : SHI) :
                     (st == E1I) ? (tms ? UPI : PAI) : (st == PAI) ? (tms ? E2I : PAI) : (st == E2I) ? (tms ? UPI : SHI) :
                     (tms ? SDR : RTI);

    wire [31:0] dtmcs = {14'd0, 2'b00, 1'b0, 3'd1 /*idle*/, sticky, 6'd7 /*abits*/, 4'd1 /*version 0.13*/};
    wire [1:0]  cap_op = busy ? 2'd3 : sticky;

    always @(posedge tck or negedge trst_n) begin
        if (!trst_n) begin
            st <= TLR; ir <= IR_IDCODE; ir_sh <= 5'd0; dr <= 41'd0; sticky <= 2'd0; req_tog <= 1'b0; req_addr <= 7'd0;
            req_data <= 32'd0; req_wr <= 1'b0; last_addr <= 7'd0; last_data <= 32'd0; last_op <= 2'd0;
            resp_tog_s1 <= 1'b0; resp_tog_s2 <= 1'b0;
        end else begin
            st <= nxt;
            resp_tog_s1 <= resp_tog; resp_tog_s2 <= resp_tog_s1;
            if (!busy) last_data <= resp_data;
            case (st)
                TLR: ir <= IR_IDCODE;
                CDR: case (ir)
                    IR_IDCODE: dr <= {9'd0, IDCODE};
                    IR_DTMCS:  dr <= {9'd0, dtmcs};
                    IR_DMI:    begin
                        dr <= {last_addr, busy ? last_data : resp_data, cap_op};
                        if (busy && sticky == 2'd0) sticky <= 2'd3;
                    end
                    default:   dr <= 41'd0;
                endcase
                SHD: case (ir)
                    IR_IDCODE, IR_DTMCS: dr <= {9'd0, tdi, dr[31:1]};
                    IR_DMI:              dr <= {tdi, dr[40:1]};
                    default:             dr <= {40'd0, tdi};
                endcase
                UPD: case (ir)
                    IR_DTMCS: if (dr[16]) sticky <= 2'd0;                           // dmireset
                    IR_DMI: begin
                        if (dr[1:0] == 2'd1 || dr[1:0] == 2'd2) begin
                            if (sticky != 2'd0) begin end                           // loi truoc do chua xoa: bo qua
                            else if (busy) sticky <= 2'd3;
                            else begin
                                req_tog <= ~req_tog; req_addr <= dr[40:34]; req_data <= dr[33:2]; req_wr <= (dr[1:0] == 2'd2);
                                last_addr <= dr[40:34];
                            end
                        end
                    end
                    default: ;
                endcase
                CIR: ir_sh <= 5'b00001;
                SHI: ir_sh <= {tdi, ir_sh[4:1]};
                UPI: ir <= ir_sh;
                default: ;
            endcase
        end
    end
    always @(negedge tck or negedge trst_n) begin
        if (!trst_n) tdo <= 1'b0;
        else tdo <= (st == SHD) ? dr[0] : (st == SHI) ? ir_sh[0] : 1'b0;
    end

    // ---- mien clk ----
    reg        rq_s1, rq_s2, rq_prev;
    reg        resp_tog_r;
    reg [31:0] resp_data_r;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin rq_s1 <= 1'b0; rq_s2 <= 1'b0; rq_prev <= 1'b0; resp_tog_r <= 1'b0; resp_data_r <= 32'd0; end
        else begin
            rq_s1 <= req_tog; rq_s2 <= rq_s1; rq_prev <= rq_s2;
            if (dmi_valid) begin resp_data_r <= dmi_rdata; resp_tog_r <= ~resp_tog_r; end
        end
    end
    assign dmi_valid = (rq_s2 != rq_prev);
    assign dmi_write = req_wr;
    assign dmi_addr  = req_addr;
    assign dmi_wdata = req_data;
    assign resp_tog  = resp_tog_r;
    assign resp_data = resp_data_r;
endmodule
