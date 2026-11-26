#!/usr/bin/env python3
"""Dot bien co y cho TAGE:
  - "M" (rv32_tage.v): kiem bang tage/check_tage.py (so tung du doan voi mo hinh tham chieu) tren vet bench, bench_m,
    bench_call, bench_corr va 2 vet tong hop, 2 cau hinh (mac dinh, va 3 bang / lao hoa u moi 64 lan); bat = lech.
  - "P" (rv32im_pipeline.v, phan noi TAGE vao pipeline): kiem bang so chu ky va so lan doan sai cua cau hinh TAGE tren
    bench, bench_m, bench_call (so chinh xac o bpred/perf_bpred.py EXPECT, GCC_REF); bat = khac so hoac treo.
Dung (tu thu muc goc repo): python3 tage/mutate_tage.py [--spike SPIKE]
"""
import os, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ROOT, "cosim"))
sys.path.insert(0, os.path.join(ROOT, "bpred"))
import check_tage as ct  # noqa: E402
import gen_trace  # noqa: E402
import run_cosim as rc  # noqa: E402
import perf_bpred as pb  # noqa: E402

M = [
    ("provider la bang trung ngan nhat", "if (hit[i]) begin altp = prov; prov = i + 1; end",
     "if (hit[i] && prov == 0) begin prov = i + 1; end"),
    ("bo qua use_alt", "((prov_weak & use_alt[3]) ? alt_pred : prov_pred)", "(prov_pred)"),
    ("provider yeu chi khi ctr = 0", "wire       prov_weak = (pc_c == 3'b000) | (pc_c == 3'b111);",
     "wire       prov_weak = (pc_c == 3'b000);"),
    ("alt luon la bang co so", "wire       alt_pred  = (altp != 0) ? ~ac_c[2] : base_pred;",
     "wire       alt_pred  = base_pred;"),
    ("ctr khong bao hoa khi tang", "if (t_c[e] != 3'b011) t_c[e] <= t_c[e] + 3'd1;", "t_c[e] <= t_c[e] + 3'd1;"),
    ("u khong tang khi provider dung", "if (t_u[e] != 2'd3) t_u[e] <= t_u[e] + 2'd1;", "t_u[e] <= t_u[e];"),
    ("u cap nhat ca khi provider = alt", "if (m_ppred != m_alt) begin\n                        if (m_ppred == u_taken)",
     "if (1'b1) begin\n                        if (m_ppred == u_taken)"),
    ("use_alt cap nhat nguoc", "if (m_alt == u_taken) begin if (use_alt != 4'd15)", "if (m_alt != u_taken) begin if (use_alt != 4'd15)"),
    ("bang co so khong tang", "if (u_taken) begin if (bim[m_bidx] != 2'b11) bim[m_bidx] <= bim[m_bidx] + 2'd1; end",
     "if (u_taken) begin end"),
    ("cap phat o bang dai nhat thay vi ngan nhat", "for (i = NT - 1; i >= 0; i = i - 1)\n            if (i + 1 > m_prov",
     "for (i = 0; i < NT; i = i + 1)\n            if (i + 1 > m_prov"),
    ("cap phat bo qua u", "if (i + 1 > m_prov && t_u[i*(1<<IB) + m_idx[i*IB +: IB]] == 2'd0) alloc = i + 1;",
     "if (i + 1 > m_prov) alloc = i + 1;"),
    ("muc moi ctr manh", "t_c[e] <= u_taken ? 3'b000 : 3'b111;", "t_c[e] <= u_taken ? 3'b011 : 3'b100;"),
    ("khong giam u khi cap phat that bai",
     "<= t_u[k*(1<<IB) + m_idx[k*IB +: IB]] - 2'd1;", "<= t_u[k*(1<<IB) + m_idx[k*IB +: IB]];"),
    ("cap phat ca khi du doan dung", "wire mis = u_valid & (m_fin != u_taken) & (m_prov != NT);",
     "wire mis = u_valid & (m_prov != NT);"),
    ("khong lao hoa u", "if (&tick) begin", "if (1'b0) begin"),
    ("lao hoa sai bit", "t_u[k][phase ? 0 : 1] <= 1'b0;", "t_u[k][phase ? 1 : 0] <= 1'b0;"),
    ("lich su khong ghi ket qua", "if (h_valid) ghr <= {ghr[GL-2:0], h_taken};", "if (h_valid) ghr <= {ghr[GL-2:0], 1'b0};"),
    ("chi so bo qua lich su", "p_pc[PCB + IB +: IB] ^ f_i[IB-1:0];", "p_pc[PCB + IB +: IB];"),
    ("tag thieu gap thu hai", "^ f_t[TB-1:0] ^ {f_s[TB-2:0], 1'b0};", "^ f_t[TB-1:0];"),
    ("chi so bo qua pc cao", "p_pc[PCB +: IB] ^ p_pc[PCB + IB +: IB] ^", "p_pc[PCB +: IB] ^"),
    ("gap lich su ghi de thay vi XOR", "fold[k % w] = fold[k % w] ^ h[k];", "fold[k % w] = h[k];"),
    ("cap nhat provider lech bang", "e = (m_prov - 1) * (1<<IB) + m_idx[(m_prov-1)*IB +: IB];",
     "e = (m_prov - 1) * (1<<IB) + m_idx[(m_prov == 1 ? 1 : m_prov - 2)*IB +: IB];"),
]

P = [
    ("meta khong qua ID/EX (lay cua lenh o IF)", "idex_tmeta   <= ifid_tmeta;", "idex_tmeta   <= if_tmeta;"),
    ("meta khong qua IF/ID (lay cua lenh o IF)", "ifid_tmeta <= if_tmeta;", "ifid_tmeta <= 'd0;"),
    ("lich su dich du doan thay vi ket qua", ".h_taken(take_branch)", ".h_taken(idex_pred_taken)"),
    ("cap nhat bang theo ket qua cua lenh sau", ".u_taken(exmem_btaken)", ".u_taken(take_branch)"),
    ("IF bo qua TAGE", "wire             if_ctr = (TAGE != 0) ? t_pred : bht[if_pidx][1];",
     "wire             if_ctr = bht[if_pidx][1];"),
    ("khong cap nhat bang TAGE", "exmem_tupd  <= ex_upd & idex_branch;", "exmem_tupd  <= 1'b0;"),
]

T_CFG = (16, 4, "T")


def perf(pipe_rtl, progs, tmp):
    vvp = os.path.join(tmp, "pm.vvp")
    files = [pipe_rtl] + [os.path.join(ROOT, f) for f in pb.FILES if f != "rv32im_pipeline.v"]
    r = subprocess.run(["iverilog", "-g2012", "-o", vvp, "-DPIPE_FULL", "-DRVC", "-DBTBN=16", "-DRASN=4", "-DGHRB=0",
                        "-DTAGEON", os.path.join(rc.HERE, "tb_cosim.v")] + files, capture_output=True, text=True)
    if r.returncode:
        return "khong bien dich duoc"
    bad = []
    for name, elf in progs:
        try:
            out = subprocess.run(["vvp", "-n", vvp, f"+prog={elf[:-4]}.hex"], capture_output=True, text=True,
                                 timeout=300).stdout
        except subprocess.TimeoutExpired:
            return f"{name}: treo"
        d = {}
        for l in out.splitlines():
            if l.startswith(("BPRED", "DONE")):
                d.update(t.split("=") for t in l.split()[1:])
        if "cycles" not in d:
            return f"{name}: khong ket thuc"
        v = (int(d["cycles"]), int(d["brmiss"]), int(d["jalrmiss"]))
        if v != pb.EXPECT[T_CFG][name]:
            bad.append(f"{name}: (chu ky, nhanh sai, JALR sai) = {v}, mong doi {pb.EXPECT[T_CFG][name]}")
    return "; ".join(bad)


def main():
    spike = sys.argv[sys.argv.index("--spike") + 1] if "--spike" in sys.argv else "/opt/spike/bin/spike"
    tmp = tempfile.mkdtemp(prefix="mt_")
    traces = []
    for name, elf, isa in gen_trace.progs(tmp, 1):
        if name == "coremark":
            continue
        p = os.path.join(tmp, name + ".trace")
        gen_trace.trace(spike, elf, isa, p)
        traces.append(p)
    for s in range(2):
        p = os.path.join(tmp, f"synth{s}.trace")
        ct.synth(p, s)
        traces.append(p)
    src = open(os.path.join(ROOT, "rv32_tage.v")).read()
    caught = total = 0
    # doi chung: ban goc phai khop
    assert ct.run_cfg(ct.CFGS[0], traces, tmp, quiet=True) == 0, "ban goc khong khop mo hinh"
    for name, old, new in M:
        total += 1
        if src.count(old) != 1:
            print(f"  BO QUA  [M] {name}: chuoi goc xuat hien {src.count(old)} lan"); continue
        f = os.path.join(tmp, "rv32_tage.v")
        open(f, "w").write(src.replace(old, new))
        try:
            bad = ct.run_cfg(ct.CFGS[0], traces, tmp, rtl=f, stop=True, quiet=True) or \
                ct.run_cfg(ct.CFGS[1], traces, tmp, rtl=f, stop=True, quiet=True)
        except subprocess.CalledProcessError:
            bad = 1
        caught += bool(bad)
        print(f"  {'BAT ' if bad else 'SOT '} [M] {name}", flush=True)
    progs = [rc.build_bench(n, m, tmp) for n, m in (("bench", "rv32ic"), ("bench_m", "rv32imc"), ("bench_call", "rv32ic"))]
    for _, elf in progs:
        rc.to_hex(elf, elf[:-4] + ".hex")
    psrc = open(os.path.join(ROOT, "rv32im_pipeline.v")).read()
    ref = perf(os.path.join(ROOT, "rv32im_pipeline.v"), progs, tmp)
    assert not ref, "ban goc sai so: " + ref
    for name, old, new in P:
        total += 1
        if psrc.count(old) != 1:
            print(f"  BO QUA  [P] {name}: chuoi goc xuat hien {psrc.count(old)} lan"); continue
        d = os.path.join(tmp, "p")
        os.makedirs(d, exist_ok=True)
        f = os.path.join(d, "rv32im_pipeline.v")
        open(f, "w").write(psrc.replace(old, new))
        r = perf(f, progs, tmp)
        caught += bool(r)
        print(f"  {'BAT ' if r else 'SOT '} [P] {name}: {r[:150]}", flush=True)
    shutil.rmtree(tmp, ignore_errors=True)
    print(f"bat duoc {caught}/{total} dot bien")
    sys.exit(0 if caught == total else 1)


if __name__ == "__main__":
    main()
