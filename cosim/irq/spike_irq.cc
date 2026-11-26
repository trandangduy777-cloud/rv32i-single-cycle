// So vet tung lenh voi Spike khi co ngat (tu viet). Spike duoc dung nhu thu vien (libriscv), chay tung buoc theo vet
// cua RTL (cosim/tb_cosim.v -DIRQ), giong cach cosim cua Ibex:
// - Thoi diem nhan ngat do RTL quyet dinh (phu thuoc chu ky). Vet RTL co dong "irq cause=.. epc=.. mip=..": truoc khi
//   Spike chay lenh ke tiep, gan mip cua Spike bang mip cua RTL luc nhan ngat va cho Spike buoc 1 lan. Kiem: pc cua
//   Spike luc do = epc (diem ngat chinh xac), Spike thuc su nhan ngat (tuc mstatus.MIE va mie cho phep theo trang thai
//   kien truc cua Spike), mcause cua Spike = cause cua RTL (dung thu tu uu tien), mepc = epc, pc moi = mtvec.
// - O moi lenh thuong mip cua Spike = 0, nen Spike khong tu nhan ngat; doc CSR mip, mcycle / cycle, mhpmcounter,
//   mhpmevent (phu thuoc hien thuc) lay gia tri cua RTL; minstret / instret phai khop Spike.
// - Ngoai vi (0x0200_0000 rv32_mtimer, 0x0300_0000 nguon ngat ngoai): lenh load tra ve gia tri RTL da doc (mtime phu
//   thuoc chu ky); lenh store van duoc so dia chi / gia tri voi RTL.
// - Chong "bo doi": neu theo trang thai kien truc cua Spike co ngat duoc phep (MIE, mie & mip cua RTL) ma RTL chay
//   them qua MAXLAG lenh van chua nhan thi bao loi.
// - Moi lenh: so pc, ma lenh, thanh ghi dich + gia tri, store (dia chi, do rong, gia tri). Exception (ecall, lenh
//   khong hop le...) Spike tu xu ly, RTL khong in dong rieng.
// Dung: spike_irq <file nhi phan (dat o 0x8000_0000)> <file vet RTL> [isa]
// Ma thoat 0: khop toan bo va chuong trinh ghi 1 vao TOHOST. In "IRQSTAT ..." (so lenh, so ngat theo loai...).
#include <riscv/processor.h>
#include <riscv/simif.h>
#include <riscv/mmu.h>
#include <riscv/cfg.h>
#include <riscv/encoding.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <vector>
#include <map>

static const reg_t BASE = 0x80000000, MEMSZ = 0x200000, TOHOST = 0x80100000;
static const reg_t DEV_LO = 0x02000000, DEV_HI = 0x04000000;
static const int MAXLAG = 8;

struct Rec {               // mot dong vet RTL
    bool irq = false;
    uint32_t pc = 0, ins = 0, rd = 0, val = 0, st = 0, addr = 0, strb = 0, mip = 0, cause = 0, epc = 0;
    uint64_t data = 0;
    std::string line;
};

class Sim : public simif_t {
public:
    std::vector<char> ram;
    cfg_t cfg;
    std::map<size_t, processor_t*> harts;
    const Rec* cur = nullptr;   // dong RTL dang so (gia tri load ngoai vi)
    long n_devld = 0, n_devst = 0;
    Sim() : ram(MEMSZ, 0) {}
    char* addr_to_mem(reg_t a) override { return (a >= BASE && a < BASE + MEMSZ) ? &ram[a - BASE] : nullptr; }
    bool mmio_load(reg_t a, size_t len, uint8_t* b) override {
        if (a < DEV_LO || a >= DEV_HI || !cur) return false;
        for (size_t i = 0; i < len; i++) b[i] = (cur->val >> (8 * i)) & 0xff;
        n_devld++;
        return true;
    }
    bool mmio_store(reg_t a, size_t, const uint8_t*) override {
        if (a < DEV_LO || a >= DEV_HI) return false;
        n_devst++;
        return true;
    }
    void proc_reset(unsigned) override {}
    const cfg_t& get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t*>& get_harts() const override { return harts; }
    const char* get_symbol(uint64_t) override { return nullptr; }
};

static bool parse(const std::string& l, Rec& r) {
    r.line = l;
    if (l.rfind("irq ", 0) == 0) {
        r.irq = true;
        return sscanf(l.c_str(), "irq cause=%x epc=%x mip=%x", &r.cause, &r.epc, &r.mip) == 3;
    }
    if (l.rfind("pc=", 0) != 0) return false;
    unsigned long long d;
    int n = sscanf(l.c_str(), "pc=%x ins=%x rd=%u val=%x st=%u addr=%x data=%llx strb=%x mip=%x",
                   &r.pc, &r.ins, &r.rd, &r.val, &r.st, &r.addr, &d, &r.strb, &r.mip);
    r.data = d;
    return n == 9;
}

int main(int argc, char** argv) {
    if (argc < 3) { fprintf(stderr, "dung: %s <bin> <vet RTL> [isa] [che do: M | MSU] [sv32]\n", argv[0]); return 2; }
    const char* isa = argc > 3 ? argv[3] : "rv32imc_zicsr_zifencei";
    const char* privs = argc > 4 ? argv[4] : "M";
    Sim sim;
    {
        std::ifstream f(argv[1], std::ios::binary);
        if (!f) { fprintf(stderr, "khong mo duoc %s\n", argv[1]); return 2; }
        f.read(sim.ram.data(), MEMSZ);
    }
    std::vector<Rec> tr;
    {
        std::ifstream f(argv[2]);
        std::string l;
        while (std::getline(f, l)) {
            Rec r;
            if (l.rfind("ERROR lenh bi ngat", 0) == 0) { printf("FAIL RTL: %s\n", l.c_str()); return 1; }
            if (parse(l, r)) tr.push_back(r);
            else if (l.rfind("pc=", 0) == 0 || l.rfind("irq ", 0) == 0) {
                printf("FAIL dong vet RTL khong doc duoc (X/Z?): %s\n", l.c_str()); return 1;
            }
        }
    }
    sim.cfg.pmpregions = 8;        // = PMP_N cua rv32im_pipeline.v
    sim.cfg.wfi_as_nop = true;     // RTL dung WFI cho toi khi co ngat dang cho; voi Spike WFI chi la mot lenh
    FILE* devnull = fopen("/dev/null", "w");
    processor_t p(isa, privs, &sim.cfg, &sim, 0, false, devnull, std::cerr);
    sim.harts[0] = &p;
    if (argc > 5 && !strcmp(argv[5], "sv32")) p.set_max_vaddr_bits(32);   // MMU Sv32 (truoc reset: tao lai CSR)
    p.reset();
    p.enable_log_commits();
    state_t* s = p.get_state();
    s->pc = BASE;
    const reg_t IRQ_MASK = MIP_MEIP | MIP_MTIP | MIP_MSIP;            // chan ngat ngoai lo (testbench dieu khien)
    const reg_t ALL_IRQ = IRQ_MASK | MIP_SEIP | MIP_STIP | MIP_SSIP;     // ngat S: phan mem ghi, Spike tu theo doi
    // ngat dang cho va duoc phep theo trang thai kien truc cua Spike (che do, MIE / SIE, mideleg)
    auto irq_allowed = [&](reg_t pend) -> bool {
        reg_t ms = s->mstatus->read(), deleg = s->mideleg->read(), prv = s->prv;
        bool m_en = prv < PRV_M || (ms & MSTATUS_MIE);
        bool s_en = prv < PRV_S || (prv == PRV_S && (ms & MSTATUS_SIE));
        return ((pend & ~deleg) && m_en) || ((pend & deleg) && s_en && prv <= PRV_S);
    };
    s->mip->backdoor_write_with_mask(IRQ_MASK, 0);

    long n_ins = 0, n_exc = 0, n_patch = 0, lag = 0, maxlag_seen = 0;
    std::map<uint32_t, long> n_irq;
    std::map<std::string, long> irq_on;      // loai lenh bi ngat (theo opcode cua lenh tai epc)
    std::vector<std::string> hist;
    auto fail = [&](size_t i, const std::string& why) {
        printf("FAIL tai dong vet %zu: %s\n", i, why.c_str());
        for (auto& h : hist) printf("      %s\n", h.c_str());
        printf("   RTL: %s\n", tr[i].line.c_str());
        return 1;
    };
    // doc ma lenh tai pc de so voi vet RTL: khi dang dich dia chi (Sv32, che do < M) thi tu duyet bang trang trong RAM
    // (khong kiem quyen; loi -> 0), moi nua 16 bit dich rieng vi lenh 32 bit co the vat qua ranh gioi trang
    auto rd16 = [&](reg_t pa) -> uint32_t {
        if (pa < BASE || pa + 2 > BASE + MEMSZ) return 0;
        uint16_t h; memcpy(&h, &sim.ram[pa - BASE], 2);
        return h;
    };
    auto xlate = [&](reg_t va, reg_t& pa) -> bool {
        reg_t satp = s->satp->read();
        if (s->prv == PRV_M || !(satp & 0x80000000u)) { pa = va; return true; }
        reg_t a = (satp & 0x3fffff) << 12;
        for (int lv = 1; lv >= 0; lv--) {
            reg_t pte_a = a + (((va >> (12 + 10 * lv)) & 0x3ff) << 2);
            if (pte_a < BASE || pte_a + 4 > BASE + MEMSZ) return false;
            uint32_t pte; memcpy(&pte, &sim.ram[pte_a - BASE], 4);
            if (!(pte & 1)) return false;
            reg_t ppn = pte >> 10;
            if (pte & 0xe) { pa = lv ? (((ppn >> 10) << 22) | (va & 0x3fffff)) : ((ppn << 12) | (va & 0xfff)); return true; }
            a = ppn << 12;
        }
        return false;
    };
    auto fetch = [&](reg_t pc) -> uint32_t {
        reg_t pa;
        if (!xlate(pc, pa)) return 0;
        uint32_t lo = rd16(pa);
        if ((lo & 3) != 3) return lo;
        if (!xlate(pc + 2, pa)) return lo;
        return lo | (rd16(pa) << 16);
    };
    char buf[256];
    for (size_t i = 0; i < tr.size(); i++) {
        const Rec& r = tr[i];
        sim.cur = &r;
        if (r.irq) {
            if ((uint32_t)s->pc != r.epc) {
                snprintf(buf, sizeof buf, "RTL nhan ngat truoc lenh %08x nhung Spike dang o %08lx", r.epc, (long)s->pc);
                return fail(i, buf);
            }
            reg_t ins0 = s->minstret->read();
            s->mip->backdoor_write_with_mask(IRQ_MASK, r.mip & IRQ_MASK);
            p.step(1);
            s->mip->backdoor_write_with_mask(IRQ_MASK, 0);
            bool to_s = s->prv == PRV_S && (uint32_t)s->scause->read() == r.cause && (uint32_t)s->sepc->read() == r.epc;
            reg_t mc = (uint32_t)(to_s ? s->scause : s->mcause)->read(), me = (uint32_t)(to_s ? s->sepc : s->mepc)->read();
            reg_t mt = (uint32_t)(to_s ? s->stvec : s->mtvec)->read();
            reg_t tv = (mt & ~(reg_t)3) + ((mt & 1) ? 4 * (r.cause & 0x3f) : 0);   // xtvec vectored
            if (s->minstret->read() != ins0 || mc != (reg_t)r.cause || me != r.epc || (uint32_t)s->pc != tv) {
                snprintf(buf, sizeof buf, "Spike khong nhan ngat giong RTL (mstatus=%08lx mie=%08lx): mcause %08lx (RTL %08x), "
                         "mepc %08lx (RTL %08x), pc %08lx (mtvec %08lx)", (long)s->mstatus->read(), (long)s->mie->read(),
                         (long)mc, r.cause, (long)me, r.epc, (long)s->pc, (long)tv);
                return fail(i, buf);
            }
            n_irq[r.cause]++;
            uint32_t w = fetch(r.epc);
            std::string k = (w & 3) != 3 ? "nen" : ((w & 0x7f) == 0x33 && ((w >> 25) & 1)) ? "M" :
                            (w & 0x7f) == 0x03 ? "load" : (w & 0x7f) == 0x23 ? "store" : (w & 0x7f) == 0x63 ? "nhanh" :
                            ((w & 0x7f) == 0x6f || (w & 0x7f) == 0x67) ? "nhay" : (w & 0x7f) == 0x73 ? "csr" : "khac";
            irq_on[k]++;
            lag = 0;
            hist.push_back(r.line);
            if (hist.size() > 4) hist.erase(hist.begin());
            continue;
        }
        // lenh thuong. Lenh gay exception (ECALL, lenh khong hop le...): RTL in mot dong khong ghi gi, Spike khong tinh la
        // hoan tat (minstret khong tang) va nhay toi trap handler.
        bool done = false;
        {
            reg_t pc0 = (uint32_t)s->pc, ins0 = s->minstret->read();
            uint32_t w = fetch(pc0);
            s->log_reg_write.clear(); s->log_mem_write.clear();
            p.step(1);
            // exception: pc moi = mtvec (exception luon ve BASE) va mepc = pc cua lenh (khong dung minstret vi
            // mcountinhibit.IR co the dung no)
            reg_t mt = (uint32_t)s->mtvec->read(), st = (uint32_t)s->stvec->read();
            bool exc = ((uint32_t)s->pc == (mt & ~(reg_t)3) && (uint32_t)s->mepc->read() == pc0) ||
                       (s->prv == PRV_S && (uint32_t)s->pc == (st & ~(reg_t)3) && (uint32_t)s->sepc->read() == pc0);
            (void)ins0;
            if (exc) {
                // loi fetch (ma 1 / 12): ma lenh khong doc duoc, RTL in gia tri bat ky -> khong so ma lenh
                reg_t ec = (s->prv == PRV_S && (uint32_t)s->sepc->read() == pc0) ? s->scause->read() : s->mcause->read();
                bool ifault = ec == 1 || ec == 12;
                if (pc0 != r.pc || (!ifault && w != r.ins) || r.rd != 0 || r.st != 0) {
                    snprintf(buf, sizeof buf, "Spike gap exception (mcause %lx) tai pc=%08lx ins=%08x",
                             (long)s->mcause->read(), (long)pc0, w);
                    return fail(i, buf);
                }
                n_exc++;
                n_ins++;
                hist.push_back(r.line);
                if (hist.size() > 4) hist.erase(hist.begin());
                continue;
            }
            done = true;
            if (pc0 != r.pc || w != r.ins) {
                snprintf(buf, sizeof buf, "Spike chay pc=%08lx ins=%08x", (long)pc0, w);
                return fail(i, buf);
            }
            uint32_t rd = 0, val = 0;
            for (auto& it : s->log_reg_write)
                if ((it.first & 0xf) == 0 && (it.first >> 4) != 0) { rd = it.first >> 4; val = (uint32_t)s->XPR[rd]; }
            bool csr_rd = (w & 0x7f) == 0x73 && ((w >> 12) & 3) != 0;
            uint32_t csr = w >> 20;
            // gia tri phu thuoc hien thuc: mip, mcycle / cycle, mhpmcounter / hpmcounter, mhpmevent, mvendorid / marchid /
            // mimpid -> lay theo RTL.
            // minstret / instret la dai luong kien truc: phai khop Spike.
            bool impl = csr == CSR_MIP || ((csr >> 8) == 0xB || (csr >> 8) == 0xC) && ((csr >> 5) & 3) == 0 &&
                        (csr & 0x1f) != 2 || (csr >= 0x323 && csr <= 0x33f) ||
                        csr == CSR_MVENDORID || csr == CSR_MARCHID || csr == CSR_MIMPID;   // ma nha san xuat / kien truc
            if (csr_rd && rd && impl && rd == r.rd && val != r.val) {
                s->XPR.write(rd, r.val); val = r.val; n_patch++;
            }
            if (rd != r.rd || val != (r.rd ? r.val : 0)) {
                snprintf(buf, sizeof buf, "Spike ghi x%u=%08x", rd, val);
                return fail(i, buf);
            }
            // store
            bool sst = !s->log_mem_write.empty();
            if (sst != (r.st == 1)) {
                snprintf(buf, sizeof buf, "Spike %s store", sst ? "co" : "khong co");
                return fail(i, buf);
            }
            if (sst) {
                auto [a, v, sz] = s->log_mem_write[0];
                uint32_t off = __builtin_ctz(r.strb), size = __builtin_popcount(r.strb);
                uint64_t m = size >= 8 ? ~0ull : ((1ull << (8 * size)) - 1);
                uint64_t rv = (r.data >> (8 * off)) & m;
                if ((uint32_t)a != (r.addr & ~3u) + off || sz != size || (v & m) != rv) {
                    snprintf(buf, sizeof buf, "Spike store [%08lx](%uB)=%lx", (long)a, (unsigned)sz, (long)(v & m));
                    return fail(i, buf);
                }
                reg_t a_pa = a;
                if (!xlate(a, a_pa)) a_pa = a;          // Spike ghi dia chi ao: TOHOST so theo dia chi vat ly
                if ((uint32_t)a_pa == TOHOST) {
                    printf("IRQSTAT instr=%ld irq_ext=%ld irq_soft=%ld irq_timer=%ld mip_reads=%ld dev_loads=%ld "
                           "dev_stores=%ld exceptions=%ld maxlag=%ld tohost=%lu\n", n_ins + 1, n_irq[0x8000000b], n_irq[0x80000003],
                           n_irq[0x80000007], n_patch, sim.n_devld, sim.n_devst, n_exc, maxlag_seen, (unsigned long)v);
                    std::string on;
                    for (auto& [k, c] : irq_on) on += " " + k + "=" + std::to_string(c);
                    printf("IRQON%s\n", on.c_str());
                    return v == 1 ? 0 : 1;
                }
            }
        }
        if (!done) return fail(i, "khong hoan tat lenh nao");
        n_ins++;
        // WFI chi duoc hoan tat khi co ngat dang cho va duoc bat trong mie (Spike chay WFI nhu NOP nen phai kiem rieng)
        if (r.ins == 0x10500073 && !(r.mip & s->mie->read() & ALL_IRQ))
            return fail(i, "WFI hoan tat khi khong co ngat nao dang cho va duoc bat trong mie");
        // chong bo doi: ngat dang cho cua RTL duoc phep theo trang thai cua Spike ma RTL chua nhan
        bool want = irq_allowed(r.mip & s->mie->read() & ALL_IRQ);
        lag = want ? lag + 1 : 0;
        if (lag > maxlag_seen) maxlag_seen = lag;
        if (lag > MAXLAG) return fail(i, "RTL de ngat duoc phep cho qua " + std::to_string(MAXLAG) + " lenh ma khong nhan");
        hist.push_back(r.line);
        if (hist.size() > 4) hist.erase(hist.begin());
    }
    printf("FAIL het vet RTL ma chua ghi TOHOST (%ld lenh)\n", n_ins);
    return 1;
}
