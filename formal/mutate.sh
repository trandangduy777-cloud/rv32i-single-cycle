#!/bin/bash
# Chen loi co y vao ban sao cua RTL va kiem tra check riscv-formal tuong ung PHAI FAIL (chung to check bat duoc loi).
#   bash formal/mutate.sh            # chay moi dot bien
#   bash formal/mutate.sh <ten>...   # chi chay cac dot bien co ten
# Moi dong, ngan cach bang #: ten, tep, doan goc (xuat hien dung 1 lan), doan thay, regex check can FAIL [, cfg trong formal/ (mac dinh checks.cfg)]
set -u
HERE=$(cd "$(dirname "$0")/.." && pwd)
BASE=${WORK:-/tmp/formal-work}
MUTS=(
"sltu_signed#rv32im_pipeline.v#3'b011: alu_out = (op_a < alu_b)#3'b011: alu_out = (\$signed(op_a) < \$signed(alu_b))#^insn_sltu_ch0$"
"bgeu_nguoc#rv32im_pipeline.v#3'b111:  take_branch = ~ltu;#3'b111:  take_branch = ltu;#^insn_bgeu_ch0$"
"sh_strobe#rv32im_pipeline.v#st_wide = {48'b0, exmem_store_val[15:0]}; st_strb8 = 8'b0000_0011;#st_wide = {48'b0, exmem_store_val[15:0]}; st_strb8 = 8'b0000_0001;#^insn_sh_ch0$"
"lb_dau#rv32im_pipeline.v#3'b000:  ld_data = {{24{ld_sh[7]}},  ld_sh[7:0]};#3'b000:  ld_data = {{24{ld_sh[6]}},  ld_sh[7:0]};#^insn_lb_ch0$"
"fwd_sai_rs#rv32im_pipeline.v#(exmem_rd != 5'd0) & (exmem_rd == rs1);#(exmem_rd != 5'd0) & (exmem_rd == rs2);#^reg_ch0$"
"fence_treo#rv32im_pipeline.v#assign ex_stall = (idex_mext & ~m_done) | wfi_wait | dwait | xp_wait;#assign ex_stall = (idex_mext & ~m_done) | wfi_wait | dwait | xp_wait | idex_fence_r;#^liveness_ch0$"
"mscratch_bit31#rv32im_pipeline.v#12'h340: mscratch <= csr_new;#12'h340: mscratch <= {1'b0, csr_new[30:0]};#^csrc_any_mscratch_ch0$"
"mie_bit#rv32im_pipeline.v#mie_mtie <= csr_new[7];#mie_mtie <= csr_new[6];#^csrc_any_mie_ch0$"
"mtvec_mode#rv32im_pipeline.v#mtvec_vec <= csr_new[0];#mtvec_vec <= csr_new[1];#^csrc_any_mtvec_ch0$"
"x0_ghi#rv32im_pipeline.v#wire rv_rdw = memwb_rd_we & (memwb_rd != 5'd0);#wire rv_rdw = memwb_rd_we;#^insn_add_ch0$"
"wfi_ket#rv32im_pipeline.v#assign ex_stall = (idex_mext & ~m_done) | wfi_wait | dwait | xp_wait;#assign ex_stall = (idex_mext & ~m_done) | wfi_wait | dwait | xp_wait | idex_wfi;#^liveness_ch0\$#checks_wfi.cfg"
"ill_mtval#rv32im_pipeline.v#begin trap_cause = 32'd2;  trap_tval = idex_instr; end#begin trap_cause = 32'd2;  trap_tval = 32'd0;      end#^trapcsr_ill_mtval_ch0\$"
"ill_mcause#rv32im_pipeline.v#begin trap_cause = 32'd2;  trap_tval = idex_instr; end#begin trap_cause = 32'd3;  trap_tval = idex_instr; end#^trapcsr_ill_mcause_ch0\$"
"ld_mtval#rv32im_pipeline.v#trap_tval = (idex_load | idex_store) ? dva : bad_target;#trap_tval = (idex_load | idex_store) ? {dva[31:2], 2'b00} : bad_target;#^trapcsr_ld_mtval_ch0\$"
"st_mcause#rv32im_pipeline.v#else if (st_misal)   trap_cause = 32'd6;#else if (st_misal)   trap_cause = 32'd4;#^trapcsr_st_mcause_ch0\$"
"ma_ld_ghep#rv32im_pipeline.v#wire [63:0] ld_wide = ma_phase ? {dmem_rdata, ma_lo} : {32'b0, dmem_rdata};#wire [63:0] ld_wide = ma_phase ? {ma_lo, dmem_rdata} : {32'b0, dmem_rdata};#^mon_misal_ch0\$#checks_misal.cfg"
"ma_st_pha#rv32im_pipeline.v#wire [31:0] st_data = ma_phase ? st_wide[63:32] : st_wide[31:0];#wire [31:0] st_data = ma_phase ? st_wide[31:0] : st_wide[63:32];#^mon_misal_ch0\$#checks_misal.cfg"
"ma_st_strb#rv32im_pipeline.v#wire [3:0]  st_strb = ma_phase ? st_strb8[7:4]  : st_strb8[3:0];#wire [3:0]  st_strb = ma_phase ? st_strb8[3:0]  : st_strb8[7:4];#^mon_misal_ch0\$#checks_misal.cfg"
"mepc_pc4#rv32im_pipeline.v#tepc_q       <= idex_pc[31:1];#tepc_q       <= idex_pc[31:1] + 31'd2;#^trapcsr_mepc_ch0$"
"mcause_ecall#rv32im_pipeline.v#begin trap_cause = {28'd0, 2'b10, priv}; trap_tval = 32'd0; end#begin trap_cause = {28'd0, 2'b10, priv ^ 2'b01}; trap_tval = 32'd0; end#^trapcsr_mcause_ch0$"
"mtval_ebreak#rv32im_pipeline.v#begin trap_cause = 32'd3;  trap_tval = idex_pc;    end#begin trap_cause = 32'd3;  trap_tval = 32'd0;      end#^trapcsr_mtval_ch0$"
"mpie_trap#rv32im_pipeline.v#mstatus_mpie <= mstatus_mie;#mstatus_mpie <= 1'b1;#^trapcsr_mstatus_ch0$"
"mret_mie#rv32im_pipeline.v#mstatus_mie  <= mstatus_mpie;#mstatus_mie  <= 1'b0;#^trapcsr_mret_ch0$"
)
sel=("$@")
res=0
for m in "${MUTS[@]}"; do
    IFS='#' read -r name file old new chk cfg <<< "$m"
    if [ ${#sel[@]} -gt 0 ] && [[ ! " ${sel[*]} " == *" $name "* ]]; then continue; fi
    d=$BASE-mut-$name
    rm -rf "$d.src"; mkdir -p "$d.src/formal"
    cp "$HERE"/rv32im_pipeline.v "$HERE"/rv32i_core.v "$HERE"/rv32c_decompress.v "$d.src/"; cp "$HERE"/formal/wrapper.sv "$d.src/formal/"
    python3 - "$d.src/$file" "$old" "$new" <<'PY' || { echo "$name: KHONG TIM THAY doan goc"; res=1; continue; }
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, s.count(old)
open(p, "w").write(s.replace(old, new))
PY
    [ -d "$d" ] || { mkdir -p "$d"; cp -r "$BASE/riscv-formal" "$d/"; }
    out=$(CFG=$HERE/formal/${cfg:-checks.cfg} WORK=$d RTL_DIR=$d.src JOBS=1 bash "$HERE/formal/run.sh" run "$chk" 2>&1 | grep -E "^[a-z_0-9]+: ")
    echo "$name -> $out"
    echo "$out" | grep -q "FAIL" || res=1
done
exit $res
