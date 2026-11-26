#!/usr/bin/env python3
"""Mo hinh tham chieu cua rv32_tage.v (viet doc lap tu mo ta trong dau file RTL, khong dich tu RTL).
Dung lam thu vien (class Tage) hoac chay truc tiep: python3 tage/tage_model.py <vet> [NT IB TB BB RST_LOG HL...]
in "P <du doan>" moi nhanh va dong DONE nhu tage/tb_tage.v.
"""
import sys


def fold(h, length, w):
    r = 0
    for k in range(length):
        if (h >> k) & 1:
            r ^= 1 << (k % w)
    return r


class Tage:
    def __init__(self, nt=4, ib=6, tb=8, bb=7, pcb=1, hl=(4, 8, 16, 32), rst_log=11):
        self.nt, self.ib, self.tb, self.bb, self.pcb, self.hl, self.rst_log = nt, ib, tb, bb, pcb, list(hl), rst_log
        self.gl = max(hl)
        self.ghr = 0
        self.bim = [1] * (1 << bb)
        n = 1 << ib
        self.ctr = [[0] * n for _ in range(nt)]          # -4..3
        self.tag = [[0] * n for _ in range(nt)]
        self.u = [[0] * n for _ in range(nt)]
        self.use_alt = 8
        self.tick = 0
        self.phase = 0

    def _bits(self, pc, lo, w):
        return (pc >> lo) & ((1 << w) - 1)

    def predict(self, pc):
        ib, tb = self.ib, self.tb
        idx, tag = [], []
        for i in range(self.nt):
            L = self.hl[i]
            idx.append(self._bits(pc, self.pcb, ib) ^ self._bits(pc, self.pcb + ib, ib) ^ fold(self.ghr, L, ib))
            tag.append((self._bits(pc, self.pcb, tb) ^ fold(self.ghr, L, tb) ^ (fold(self.ghr, L, tb - 1) << 1))
                       & ((1 << tb) - 1))
        bidx = self._bits(pc, self.pcb, self.bb)
        prov = alt = -1
        for i in range(self.nt):
            if self.tag[i][idx[i]] == tag[i]:
                alt, prov = prov, i
        base = self.bim[bidx] >= 2
        alt_pred = (self.ctr[alt][idx[alt]] >= 0) if alt >= 0 else base
        if prov < 0:
            fin, ppred, pweak = base, False, False
        else:
            c = self.ctr[prov][idx[prov]]
            ppred, pweak = c >= 0, c in (0, -1)
            fin = alt_pred if (pweak and self.use_alt >= 8) else ppred
        meta = dict(fin=fin, alt=alt_pred, ppred=ppred, pweak=pweak, prov=prov, bidx=bidx, idx=idx, tag=tag)
        return fin, meta

    def update(self, taken, m):
        prov = m["prov"]
        if prov >= 0:
            e = m["idx"][prov]
            c = self.ctr[prov][e]
            self.ctr[prov][e] = min(c + 1, 3) if taken else max(c - 1, -4)
            if m["ppred"] != m["alt"]:
                uu = self.u[prov][e]
                self.u[prov][e] = min(uu + 1, 3) if m["ppred"] == taken else max(uu - 1, 0)
            if m["pweak"] and m["ppred"] != m["alt"]:
                self.use_alt = min(self.use_alt + 1, 15) if m["alt"] == taken else max(self.use_alt - 1, 0)
        else:
            b = self.bim[m["bidx"]]
            self.bim[m["bidx"]] = min(b + 1, 3) if taken else max(b - 1, 0)
        if m["fin"] != taken and prov < self.nt - 1:
            cand = [j for j in range(prov + 1, self.nt) if self.u[j][m["idx"][j]] == 0]
            if cand:
                j = cand[0]
                e = m["idx"][j]
                self.tag[j][e] = m["tag"][j]
                self.ctr[j][e] = 0 if taken else -1
                self.u[j][e] = 0
            else:
                for j in range(prov + 1, self.nt):
                    e = m["idx"][j]
                    self.u[j][e] = max(self.u[j][e] - 1, 0)
        if self.tick == (1 << self.rst_log) - 1:
            bit = 0 if self.phase else 1
            for t in self.u:
                for x in range(len(t)):
                    t[x] &= ~(1 << bit)
            self.phase ^= 1
        self.tick = (self.tick + 1) & ((1 << self.rst_log) - 1)

    def history(self, taken):
        self.ghr = ((self.ghr << 1) | int(taken)) & ((1 << self.gl) - 1)


def main():
    a = sys.argv[1:]
    nt, ib, tb, bb, rl = (int(x) for x in a[1:6]) if len(a) >= 6 else (4, 6, 8, 7, 11)
    hl = [int(x) for x in a[6:]] if len(a) > 6 else [4, 8, 16, 32]
    t = Tage(nt, ib, tb, bb, 1, hl, rl)
    n = nm = 0
    for line in open(a[0]):
        p = line.split()
        if len(p) != 2:
            continue
        pc, tk = int(p[0], 16), int(p[1]) & 1
        pr, m = t.predict(pc)
        print(f"P {int(pr)}")
        n += 1
        nm += int(pr) != tk
        t.update(bool(tk), m)
        t.history(tk)
    print(f"DONE n={n} miss={nm}")


if __name__ == "__main__":
    main()
