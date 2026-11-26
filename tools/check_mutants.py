#!/usr/bin/env python3
"""Kiem moi danh sach dot bien trong repo: chuoi goc cua moi dot bien phai xuat hien DUNG 1 lan trong file dich.

Sua RTL ma quen cap nhat chuoi goc thi dot bien bi bo qua (BO QUA / KHONG TIM THAY) hoac thay nham cho, va truoc day chi
lo ra sau vai gio chay mutation. Script nay chi doc danh sach (khong chay mo phong), mat vai giay, chay o dau job CI
simulate va la buoc 0 cua tools/regress.sh.

Dung: python3 tools/check_mutants.py [-v]     # thoat ma 1 neu co dot bien lech, in tung dot bien lech
"""
import ast, importlib.util, os, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load(rel):
    """Import mot script dot bien (cac script nay deu co if __name__ == "__main__") ma khong chay main."""
    path = os.path.join(ROOT, rel)
    d = os.path.dirname(path)
    if d not in sys.path:
        sys.path.insert(0, d)
    spec = importlib.util.spec_from_file_location("mut_" + rel.replace("/", "_").replace(".", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ast_list(rel, name):
    """Lay list hang (literal) gan cho ten `name` o muc module, khong import (file chay ngay khi import)."""
    tree = ast.parse(open(os.path.join(ROOT, rel)).read())
    for node in tree.body:
        if isinstance(node, ast.Assign) and any(isinstance(t, ast.Name) and t.id == name for t in node.targets):
            return ast.literal_eval(node.value)
    raise KeyError(f"{rel}: khong co {name}")


def bash_array(rel, name="MUTS"):
    """Doc mang bash `name=( ... )` trong script bang chinh bash (giu dung quy tac nhay kep, \\$ ...)."""
    lines = open(os.path.join(ROOT, rel)).read().splitlines()
    i = next(k for k, l in enumerate(lines) if l.startswith(name + "=("))
    j = next(k for k in range(i + 1, len(lines)) if lines[k].strip() == ")")
    snippet = "\n".join(lines[i:j + 1]) + f'\nprintf "%s\\0" "${{{name}[@]}}"'
    out = subprocess.run(["bash", "-c", snippet], capture_output=True, text=True, check=True).stdout
    return [e for e in out.split("\0") if e]


def collect():
    """Tra ve list (script, ten dot bien, [file dich ung vien], chuoi goc)."""
    R = []
    add = lambda src, name, files, old: R.append((src, name, files, old))

    rv = load("verify/run_verify.py")
    for lst, f in ((rv.MUTATIONS, "rv32i_core.v"), (rv.PIPE_MUTATIONS, "rv32i_pipeline.v"),
                   (rv.PIPEM_MUTATIONS, "rv32im_pipeline.v"), (rv.M_CORE_MUTATIONS, "rv32i_core.v")):
        for name, old, _new in lst:
            add("verify/run_verify.py", name, [f], old)

    irq = load("irq/mutate_irq.py")
    for name, old, _new in irq.MUTATIONS:
        add("irq/mutate_irq.py", name, ["rv32im_pipeline.v"], old)

    for name, fn, old, *_ in load("cache/mutate_cache.py").MUTATIONS:
        add("cache/mutate_cache.py", name, [fn], old)
    for name, fn, old, *_ in load("rvc/mutate_rvc.py").MUTATIONS:
        add("rvc/mutate_rvc.py", name, [fn], old)
    bp = load("bpred/mutate_bpred.py")
    for name, old, *_ in bp.MUTATIONS:
        add("bpred/mutate_bpred.py", name, [bp.F], old)
    mu = load("mul/mutate_mul.py")
    for name, old, *_ in mu.MUTATIONS:
        add("mul/mutate_mul.py", name, [mu.F], old)
    zb = load("zb/mutate_zb.py")
    for name, old, *_ in zb.M:
        add("zb/mutate_zb.py", name, [zb.F], old)
    for name, fn, old, *_ in load("cosim/mutate_random.py").M:
        add("cosim/mutate_random.py", name, [fn], old)
    ic = load("cosim/irq/mutate_irq_cosim.py")
    for name, old, *_ in ic.EXTRA:      # mutate_irq.MUTATIONS da kiem o tren; dich la pipeline HOAC MMU
        add("cosim/irq/mutate_irq_cosim.py", name, [ic.F, "rv32_mmu.v"], old)

    for src in ("soc/mutate_soc.py", "soc/mutate_axi.py"):
        for i, f, old, *_ in load(src).M:
            add(src, i, [f[3:] if f.startswith("../") else "soc/" + f], old)

    for lst in ("IC", "DC"):
        for name, f, old, *_ in ast_list("formal/cache/mutate.py", lst):
            add("formal/cache/mutate.py", name, [f], old)
    for name, old, _new, _lem in ast_list("mul/formal/run_formal.py", "NEG"):   # import se tim yosys ngay
        add("mul/formal/run_formal.py", name, ["rv32i_core.v"], old)

    for e in bash_array("formal/mutate.sh"):
        name, f, old = e.split("#")[:3]
        add("formal/mutate.sh", name, [f], old)
    for e in bash_array("formal/stitch/run.sh"):
        name, old = e.split("#")[:2]
        add("formal/stitch/run.sh", name, ["rv32i_core.v"], old.replace("\\&", "&"))
    for e in bash_array("formal/div/run.sh"):
        name, old = e.split("#")[:2]
        add("formal/div/run.sh", name, ["rv32i_core.v"], old)

    if os.path.exists(os.path.join(ROOT, "tage", "mutate_tage.py")):   # TAGE (nhanh muc-tage): M o rv32_tage.v, P o pipeline
        for lst, f in (("M", "rv32_tage.v"), ("P", "rv32im_pipeline.v")):
            for name, old, _new in ast_list("tage/mutate_tage.py", lst):
                add("tage/mutate_tage.py", name, [f], old)
    return R


def main():
    verbose = "-v" in sys.argv
    cache, bad, per = {}, [], {}
    for src, name, files, old in collect():
        n = 0
        for f in files:
            if f not in cache:
                p = os.path.join(ROOT, f)
                cache[f] = open(p).read() if os.path.exists(p) else None
            if cache[f] is None:
                bad.append((src, name, f"file dich {f} khong ton tai"))
                n = -1
                break
            n += cache[f].count(old)
        per[src] = per.get(src, 0) + 1
        if n >= 0 and n != 1:
            bad.append((src, name, f"chuoi goc xuat hien {n} lan trong {' / '.join(files)}: {old[:90]!r}"))
    if verbose:
        for s, k in per.items():
            print(f"  {s}: {k} dot bien")
    for src, name, why in bad:
        print(f"[check_mutants] LECH  {src}: {name}: {why}")
    total = sum(per.values())
    print(f"[check_mutants] {total} dot bien trong {len(per)} script: "
          + ("moi chuoi goc xuat hien dung 1 lan" if not bad else f"{len(bad)} dot bien lech"))
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
