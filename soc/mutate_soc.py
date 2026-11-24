#!/usr/bin/env python3
"""Mutation test cho phan SoC: chen tung loi co y vao RTL (soc/*.v va phan mepc cua rv32im_pipeline.v), chay bo kiem chung cua run_soc.py,
moi dot bien phai bi it nhat mot buoc bat (that bai). In dot bien nao lot (khong bi bat); thoat ma 1 neu co dot bien lot hoac dot bien khong ap dung/khong bien dich.
Dung: python3 soc/mutate_soc.py [--jobs N] [--only chuoi]   (can soc/sw/build/*.hex: sh soc/sw/build.sh)"""
import os, sys, shutil, tempfile, argparse, concurrent.futures as cf
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import run_soc

ROOT = run_soc.ROOT
# (id, file, old, new, mo ta). old phai xuat hien dung 1 lan trong file.
M = []
def m(i, f, old, new, d): M.append((i, f, old, new, d))

# ---- ROM / RAM ----
m("ROM1", "soc_rom.v", "assign i_data = i_addr[1] ?", "assign i_data = !i_addr[1] ?", "ROM: chon nua tu theo bit 1 bi dao")
m("ROM2", "soc_rom.v", "iw0 + {{(AW-1){1'b0}}, 1'b1}", "iw0 + {{(AW-1){1'b0}}, 1'b0}", "ROM: lenh vat qua ranh gioi khong lay tu ke tiep")
m("ROM3", "soc_rom.v", "{mem[iw1][15:0], mem[iw0][31:16]}", "{mem[iw1][31:16], mem[iw0][15:0]}", "ROM: ghep sai nua tu khi vat ranh gioi")
m("ROM4", "soc_rom.v", "mem[d_addr[AW+1:2]]", "mem[{d_addr[AW+1:3], 1'b0}]", "ROM: cong du lieu bo bit dia chi 2")
m("RAM1", "soc_ram.v", "if (wstrb[0]) mem[w][7:0]   <= wdata[7:0];", "if (1'b1) mem[w][7:0] <= wdata[7:0];", "RAM: byte 0 ghi bat ke wstrb")
m("RAM2", "soc_ram.v", "if (wstrb[2]) mem[w][23:16] <= wdata[23:16];", "if (wstrb[2]) mem[w][23:16] <= wdata[7:0];", "RAM: byte 2 lay du lieu byte 0")
m("RAM3", "soc_ram.v", "if (sel & we) begin", "if (we) begin", "RAM: ghi khong can sel")
m("RAM4", "soc_ram.v", "if (sel & we) begin", "if (sel) begin", "RAM: ghi khi chi doc")
m("RAM5", "soc_ram.v", "wire [AW-1:0] w = addr[AW+1:2];", "wire [AW-1:0] w = addr[AW:1];", "RAM: chi so tu sai")
m("RAM6", "soc_ram.v", "if (wstrb[3]) mem[w][31:24] <= wdata[31:24];", "if (wstrb[2]) mem[w][31:24] <= wdata[31:24];", "RAM: byte 3 theo wstrb[2]")
# ---- BUS ----
m("BUS1", "soc_bus.v", "assign sel_rom   = (daddr[31:ROM_AW] == {(32-ROM_AW){1'b0}});", "assign sel_rom   = (daddr[31:ROM_AW+1] == {(31-ROM_AW){1'b0}});", "bus: ROM rong gap doi")
m("BUS2", "soc_bus.v", "assign sel_ram   = (daddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);", "assign sel_ram   = (daddr[31:RAM_AW+1] == RAM_BASE[31:RAM_AW+1]);", "bus: RAM rong gap doi")
m("BUS3", "soc_bus.v", "(daddr[31:5]  == 27'h0100000)", "(daddr[31:6]  == 26'h0080000)", "bus: CLINT rong 64 byte")
m("BUS4", "soc_bus.v", "(daddr[31:12] == 20'h20000)", "(daddr[31:13] == 19'h10000)", "bus: UART chiem ca cua so GPIO")
m("BUS5", "soc_bus.v", "20'h20001", "20'h20003", "bus: GPIO sai dia chi")
m("BUS6", "soc_bus.v", "20'h20002", "20'h20012", "bus: SYSCON sai dia chi")
m("BUS7", "soc_bus.v", "({32{sel_gpio}} & gpio_rd)", "(gpio_rd)", "bus: du lieu GPIO khong bi che theo sel")
m("BUS8", "soc_bus.v", "({32{sel_clint}} & clint_rd)", "32'd0", "bus: khong doc duoc CLINT")
m("BUS9", "soc_bus.v", "((dre | dwe) & ~any_sel) | (dwe & sel_rom)", "((dre | dwe) & ~any_sel)", "bus: ghi ROM khong bao loi")
m("BUS10", "soc_bus.v", "((dre | dwe) & ~any_sel) | (dwe & sel_rom)", "(dwe & ~any_sel) | (dwe & sel_rom)", "bus: doc ngoai vung khong bao loi")
m("BUS11", "soc_bus.v", "| sel_gpio | sel_sys | sel_plic;", "| sel_gpio | sel_plic;", "bus: SYSCON bi coi la ngoai vung")
m("BUS12", "soc_bus.v", "assign i_sel_rom = (iaddr[31:ROM_AW] == {(32-ROM_AW){1'b0}});", "assign i_sel_rom = 1'b1;", "bus: fetch ngoai ROM van tra du lieu ROM")
m("BUS13", "soc_bus.v", "({32{sel_ram}}  & ram_rd)", "({32{sel_ram}}  & rom_rd)", "bus: doc RAM tra du lieu ROM")
m("BUS14", "soc_bus.v", "assign bus_err = ((dre | dwe) & ~any_sel) | (dwe & sel_rom);", "assign bus_err = ((dre | dwe) & ~any_sel) | (dre & sel_rom);", "bus: doc ROM bi coi la loi")
# ---- PLIC ----
P = "soc_plic.v"
m("PL1", P, "(prio[j] > best_pr)", "(prio[j] >= best_pr)", "PLIC: hoa chon ID lon nhat")
m("PL2", P, "(prio[j] > thr)", "(prio[j] >= thr)", "PLIC: threshold dung >= thay vi >")
m("PL3", P, "if (pend[j] & en[j] &", "if (pend[j] &", "PLIC: bo qua enable khi chon nguon")
m("PL4", P, "if (pend[j] & en[j] &", "if (en[j] &", "PLIC: chon ca nguon khong pending")
m("PL5", P, "& (cid <= NSRC) & en[cid[4:0]] & infl[cid[4:0]];", "& (cid <= NSRC) & infl[cid[4:0]];", "PLIC: complete khong can enable")
m("PL6", P, "(cid <= NSRC) & en", "(cid < NSRC) & en", "PLIC: complete bo qua nguon cuoi")
m("PL7", P, "begin pend[i] <= 1'b0; infl[i] <= 1'b1; end", "begin pend[i] <= 1'b0; end", "PLIC: claim khong danh dau dang xu ly")
m("PL8", P, "begin pend[i] <= 1'b0; infl[i] <= 1'b1; end", "begin infl[i] <= 1'b1; end", "PLIC: claim khong xoa pending")
m("PL9", P, "if (src[i] & ~infl[i] & ~pend[i]) pend[i] <= 1'b1;", "if (src[i] & ~pend[i]) pend[i] <= 1'b1;", "PLIC: cong khong chan nguon dang xu ly")
m("PL10", P, "wr & a_cc & wstrb[0] &", "wr & a_cc &", "PLIC: complete bo qua wstrb")
m("PL11", P, "prio[pidx] <= wdata[PRIO_W-1:0];", "prio[pidx] <= {1'b0, wdata[PRIO_W-2:0]};", "PLIC: uu tien mat bit cao")
m("PL12", P, "(w[9:0] <= NSRC);", "(w[9:0] < NSRC);", "PLIC: nguon cuoi khong co thanh ghi uu tien")
m("PL13", P, "(w[9:0] >= 10'd1)", "(w[9:0] >= 10'd0)", "PLIC: co thanh ghi uu tien cho nguon 0")
m("PL14", P, "wire a_pend = (w == 20'h00400);", "wire a_pend = (w == 20'h00401);", "PLIC: dia chi pending sai")
m("PL15", P, "wire a_en   = (w == 20'h00800);", "wire a_en   = (w == 20'h00801);", "PLIC: dia chi enable sai")
m("PL16", P, "wire a_thr  = (w == 20'h80000);", "wire a_thr  = (w == 20'h80002);", "PLIC: dia chi threshold sai")
m("PL17", P, "wire a_cc   = (w == 20'h80001);", "wire a_cc   = (w == 20'h80003);", "PLIC: dia chi claim sai")
m("PL18", P, "wire claim = sel & re & a_cc;", "wire claim = sel & a_cc;", "PLIC: doc khong re cung claim")
m("PL19", P, "if (wstrb[0]) for (i = 1; i <= 7;", "if (wstrb[1]) for (i = 1; i <= 7;", "PLIC: byte 0 cua enable theo wstrb sai")
m("PL20", P, "for (i = 1; i <= 7;  i = i + 1) if (i <= NSRC) en[i] <= wdata[i];", "for (i = 2; i <= 7;  i = i + 1) if (i <= NSRC) en[i] <= wdata[i];", "PLIC: nguon 1 khong enable duoc")
m("PL21", P, "if (wr & a_thr & wstrb[0])", "if (wr & a_thr)", "PLIC: threshold bo qua wstrb")
m("PL22", P, "else if (a_pend) rdata = {{(31-NSRC){1'b0}}, pend, 1'b0};", "else if (a_pend) rdata = {{(31-NSRC){1'b0}}, infl, 1'b0};", "PLIC: doc pending ra infl")
m("PL23", P, "assign eip = (best_id != 5'd0);", "assign eip = (pend != {NSRC{1'b0}});", "PLIC: eip bo qua enable/uu tien/threshold")
m("PL24", P, "else if (a_cc)   rdata = {27'd0, best_id};", "else if (a_cc)   rdata = {27'd0, best_id} | 32'h100;", "PLIC: claim doc them bit")
m("PL26", P, "pend <= {NSRC{1'b0}}; infl <= {NSRC{1'b0}}; en <= {NSRC{1'b0}}; thr <= {PRIO_W{1'b0}};", "pend <= {NSRC{1'b0}}; infl <= {NSRC{1'b0}}; en <= {NSRC{1'b1}}; thr <= {PRIO_W{1'b0}};", "PLIC: reset de enable bat")
m("PL27", P, "else if (a_thr)  rdata = {{(32-PRIO_W){1'b0}}, thr};", "else if (a_thr)  rdata = {{(32-PRIO_W){1'b0}}, thr} + 32'd1;", "PLIC: doc threshold sai")
m("PL28", P, "if (wr & a_en) begin", "if (wr & a_en & ~infl[1]) begin", "PLIC: enable bi chan khi nguon 1 dang xu ly")
m("PLT1", "soc_top.v", ".src({ext_irq, irq_gpio, irq_uart_tx, irq_uart_rx})", ".src({ext_irq, irq_gpio, irq_uart_rx, irq_uart_tx})", "top: doi cho nguon UART RX/TX vao PLIC")
m("PLT2", "soc_top.v", ".src({ext_irq, irq_gpio, irq_uart_tx, irq_uart_rx})", ".src({irq_gpio, ext_irq[2:0], irq_uart_tx, irq_uart_rx} ^ {ext_irq[3], 6'd0})", "top: nguon ngoai 3 doi cho GPIO (lech)")
m("PLT3", "soc_top.v", ".sel(sel_plic), .addr(dmem_addr[21:2])", ".sel(sel_plic), .addr(dmem_addr[20:1])", "top: dia chi PLIC lech 1 bit")
m("PLB1", "soc_bus.v", "assign sel_plic  = (daddr[31:22] == 10'h030);", "assign sel_plic  = (daddr[31:22] == 10'h031);", "bus: PLIC sai cua so")
m("PLB2", "soc_bus.v", " | ({32{sel_plic}} & plic_rd);", ";", "bus: khong mux du lieu doc PLIC")
m("PLB3", "soc_bus.v", "sel_gpio | sel_sys | sel_plic;", "sel_gpio | sel_sys;", "bus: truy cap PLIC bi bao bus_err")
m("PLU1", "soc_uart.v", "assign irq_rx = ie[0] & rx_valid;", "assign irq_rx = ie[1] & rx_valid;", "UART: irq_rx dung nham IE")
m("PLU2", "soc_uart.v", "assign irq_tx = ie[1] & tx_ready;", "assign irq_tx = ie[0] & tx_ready;", "UART: irq_tx dung nham IE")
# ---- Them: lay lenh tu RAM, FIFO nhan UART, PRESCALE cua rv32_mtimer ----
m("RAM7", "soc_ram.v", "assign i_data = i_addr[1] ?", "assign i_data = !i_addr[1] ?", "RAM: cong lenh chon nua tu theo bit 1 bi dao")
m("RAM8", "soc_ram.v", "iw0 + {{(AW-1){1'b0}}, 1'b1}", "iw0 + {{(AW-1){1'b0}}, 1'b0}", "RAM: lenh vat qua ranh gioi khong lay tu ke tiep")
m("RAM9", "soc_ram.v", "{mem[iw1][15:0], mem[iw0][31:16]}", "{mem[iw1][31:16], mem[iw0][15:0]}", "RAM: ghep sai nua tu khi vat ranh gioi")
m("BUS15", "soc_bus.v", "assign i_sel_ram = (iaddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);", "assign i_sel_ram = 1'b0;", "bus: khong lay lenh tu RAM")
m("BUS16", "soc_bus.v", "assign i_sel_ram = (iaddr[31:RAM_AW] == RAM_BASE[31:RAM_AW]);", "assign i_sel_ram = (iaddr[31:RAM_AW+1] == RAM_BASE[31:RAM_AW+1]);", "bus: vung lenh RAM rong gap doi")
m("TOP1", "soc_top.v", "i_sel_rom ? rom_idata : i_sel_ram ? ram_idata : 32'd0", "i_sel_rom ? rom_idata : i_sel_ram ? rom_idata : 32'd0", "top: lay lenh RAM tu du lieu ROM")
m("FIFO1", "soc_uart.v", "wire [3:0] rp_n = (rp == RX_DEPTH - 1) ? 4'd0 : rp + 4'd1;", "wire [3:0] rp_n = rp + 4'd1;", "UART FIFO: con tro doc khong quay vong")
m("FIFO2", "soc_uart.v", "wire [3:0] wp_n = (wp == RX_DEPTH - 1) ? 4'd0 : wp + 4'd1;", "wire [3:0] wp_n = (wp == RX_DEPTH - 2) ? 4'd0 : wp + 4'd1;", "UART FIFO: con tro ghi quay vong som 1 muc")
m("FIFO3", "soc_uart.v", "if ((cnt == RX_DEPTH) & ~pop) rx_ovr <= 1'b1;", "if ((cnt == RX_DEPTH)) rx_ovr <= 1'b1;", "UART FIFO: day + pop cung chu ky van bi tran")
m("FIFO4", "soc_uart.v", "cnt <= (pop & rx_valid) ? cnt : cnt + 4'd1;", "cnt <= cnt + 4'd1;", "UART FIFO: pop cung push lam dem tang them")
m("FIFO5", "soc_uart.v", "if (pop & rx_valid) begin rp <= rp_n; cnt <= cnt - 4'd1; end", "if (pop) begin rp <= rp_n; cnt <= cnt - 4'd1; end", "UART FIFO: doc khi rong lam lech con tro/dem")
m("FIFO6", "soc_uart.v", "rdata = {20'd0, cnt, 3'd0, tx_drop", "rdata = {20'd0, cnt + 4'd1, 3'd0, tx_drop", "UART FIFO: STATUS bao sai so byte")
m("FIFO7", "soc_uart.v", "fifo[wp] <= rbuf; wp <= wp_n;", "fifo[wp] <= rbuf;", "UART FIFO: con tro ghi khong tang")
m("FIFO8", "soc_uart.v", "wire       rx_valid = (cnt != 4'd0);", "wire       rx_valid = (cnt > 4'd1);", "UART FIFO: RXVALID chi khi co tu 2 byte")
m("PRE1", "../rv32_mtimer.v", "wire tick = (pre == PRESCALE - 1);", "wire tick = (pre == PRESCALE);", "mtimer: chu ky tick dai hon PRESCALE 1")
m("PRE2", "../rv32_mtimer.v", "pre <= tick ? 32'd0 : pre + 32'd1;", "pre <= tick ? 32'd1 : pre + 32'd1;", "mtimer: pha lech sau moi tick")
m("PRE3", "../rv32_mtimer.v", "else if (tick)                      mtime           <= mtime + 64'd1;", "else if (tick)                      mtime[31:0]     <= mtime[31:0] + 32'd1;", "mtimer: khong carry len 32 bit cao")
m("PRE4", "../rv32_mtimer.v", "pre <= tick ? 32'd0 : pre + 32'd1;", "pre <= (tick | (sel & we)) ? 32'd0 : pre + 32'd1;", "mtimer: moi lan ghi bus dat lai pha prescaler")
# ---- UART ----
m("U1", "soc_uart.v", "txs <= {1'b1, wdata[7:0], 1'b0};", "txs <= {1'b1, wdata[0], wdata[1], wdata[2], wdata[3], wdata[4], wdata[5], wdata[6], wdata[7], 1'b0};", "UART TX: MSB truoc")
m("U2", "soc_uart.v", "txs <= {1'b1, wdata[7:0], 1'b0};", "txs <= {1'b0, wdata[7:0], 1'b0};", "UART TX: bit stop = 0")
m("U3", "soc_uart.v", "txs <= {1'b1, wdata[7:0], 1'b0};", "txs <= {1'b1, wdata[7:0], 1'b1};", "UART TX: bit start = 1")
m("U4", "soc_uart.v", "txc <= txd - 16'd1; txs <= {1'b1, txs[9:1]};", "txc <= txd; txs <= {1'b1, txs[9:1]};", "UART TX: bit thu 2 tro di dai them 1 chu ky")
m("U5", "soc_uart.v", "txc <= div - 16'd1; txn <= 4'd0; busy <= 1'b1;", "txc <= div; txn <= 4'd0; busy <= 1'b1;", "UART TX: bit start dai them 1 chu ky")
m("U6", "soc_uart.v", "if (txn == 4'd9) busy <= 1'b0;", "if (txn == 4'd8) busy <= 1'b0;", "UART TX: bit stop bi cat")
m("U7", "soc_uart.v", "if (wr_tx & ~busy) begin", "if (wr_tx) begin", "UART TX: nhan byte khi dang ban")
m("U8", "soc_uart.v", "if (wr_tx & busy) tx_drop <= 1'b1;", "if (1'b0) tx_drop <= 1'b1;", "UART: khong dat TXDROP")
m("U9", "soc_uart.v", "txc <= txd - 16'd1; txs <= {1'b1, txs[9:1]};", "txc <= div - 16'd1; txs <= {1'b1, txs[9:1]};", "UART TX: DIV doi giua khung co hieu luc ngay")
m("U10", "soc_uart.v", "(div_new < 16'd4) ? 16'd4 : div_new", "(div_new < 16'd3) ? 16'd4 : div_new", "UART: DIV = 3 duoc chap nhan")
m("U11", "soc_uart.v", "(div_new < 16'd4) ? 16'd4 : div_new", "div_new", "UART: khong chan DIV nho")
m("U12", "soc_uart.v", "wire [15:0] wmask16 = {{8{wstrb[1]}}, {8{wstrb[0]}}};", "wire [15:0] wmask16 = {16{1'b1}};", "UART: ghi DIV bo qua byte-lane")
m("U13", "soc_uart.v", "(wstrb[1] | wstrb[0])", "wstrb[0]", "UART: ghi byte cao cua DIV bi mat")
m("U14", "soc_uart.v", "rc <= {1'b0, div[15:1]} - 16'd1;", "rc <= div - 16'd1;", "UART RX: lay mau tre nua bit")
m("U15", "soc_uart.v", "rbuf <= {rx_s2, rbuf[7:1]};", "rbuf <= {rbuf[6:0], rx_s2};", "UART RX: MSB truoc")
m("U16", "soc_uart.v", "if (rx_s2) rst_ <= 3'd0;                  // nhieu, khong phai bit start", "if (1'b0) rst_ <= 3'd0;", "UART RX: khong loc nhieu bit start")
m("U17", "soc_uart.v", "if ((cnt == RX_DEPTH) & ~pop) rx_ovr <= 1'b1;", "if ((cnt == RX_DEPTH) & ~pop) begin rx_ovr <= 1'b1; fifo[rp] <= rbuf; end", "UART RX: overrun ghi de byte cu")
m("U18", "soc_uart.v", "if ((cnt == RX_DEPTH) & ~pop) rx_ovr <= 1'b1;", "if ((cnt == RX_DEPTH) & ~pop) rx_ovr <= 1'b0;", "UART RX: khong bao overrun")
m("U19", "soc_uart.v", "if (!rx_s2) rx_ferr <= 1'b1;", "if (rx_s2) rx_ferr <= 1'b1;", "UART RX: loi khung dao")
m("U20", "soc_uart.v", "wire       pop = sel & re & (addr == 3'd1);", "wire       pop = sel & (addr == 3'd1);", "UART RX: pop khong can re")
m("U21", "soc_uart.v", "wire       pop = sel & re & (addr == 3'd1);", "wire       pop = sel & re & (addr == 3'd2);", "UART RX: doc STATUS pop byte")
m("U22", "soc_uart.v", "if (wdata[2]) rx_ovr  <= 1'b0;", "if (wdata[3]) rx_ovr  <= 1'b0;", "UART: W1C overrun sai bit")
m("U23", "soc_uart.v", "if (wdata[3]) rx_ferr <= 1'b0;", "if (1'b1) rx_ferr <= 1'b0;", "UART: ghi STATUS xoa ferr bat ke bit")
m("U24", "soc_uart.v", "rst_ <= rx_s2 ? 3'd0 : 3'd4;", "rst_ <= 3'd0;", "UART RX: khong cho duong len cao sau loi khung")
m("U25", "soc_uart.v", "irq_rx = ie[0] & rx_valid;", "irq_rx = ie[0] | rx_valid;", "UART: irq RX khong can IE")
m("U26", "soc_uart.v", "irq_tx = ie[1] & tx_ready;", "irq_tx = ie[1];", "UART: irq TX khong can TXREADY")
m("U27", "soc_uart.v", "rdata = {20'd0, cnt, 3'd0, tx_drop, rx_ferr, rx_ovr, rx_valid, tx_ready};", "rdata = {20'd0, cnt, 3'd0, tx_drop, rx_ferr, rx_ovr, tx_ready, rx_valid};", "UART: STATUS doi cho bit 0 va 1")
m("U28", "soc_uart.v", "ie <= wdata[1:0];", "ie <= wdata[2:1];", "UART: IE lay sai bit")
m("U29", "soc_uart.v", "if (rn == 3'd7) rst_ <= 3'd3;", "if (rn == 3'd6) rst_ <= 3'd3;", "UART RX: chi 7 bit du lieu")
m("U30", "soc_uart.v", "3'd1:    rdata = {24'd0, rx_data};", "3'd1:    rdata = {24'd0, rx_valid ? rx_data : 8'd0};", "UART RX: RXDATA ve 0 sau khi doc")
m("U31", "soc_uart.v", "if (wdata[4]) tx_drop <= 1'b0;", "if (wdata[3]) tx_drop <= 1'b0;", "UART: W1C TXDROP sai bit")
m("U32", "soc_uart.v", "wire       w_status = sel & we & (addr == 3'd2) & wstrb[0];", "wire       w_status = sel & we & (addr == 3'd2);", "UART: W1C bo qua wstrb")
m("U33", "soc_uart.v", "wire       wr_tx = sel & we & (addr == 3'd0) & wstrb[0];", "wire       wr_tx = sel & we & (addr == 3'd0);", "UART: TXDATA bo qua wstrb")
m("U34", "soc_uart.v", "div <= DEFAULT_DIV; ie <= 2'b00;", "div <= 16'd4; ie <= 2'b00;", "UART: DIV reset sai")
m("U35", "soc_uart.v", "txs <= {1'b1, wdata[7:0], 1'b0}; txd <= div;", "txs <= {1'b1, wdata[7:0], 1'b0}; txd <= DEFAULT_DIV;", "UART TX: chot DIV mac dinh thay vi DIV hien tai")
# ---- GPIO ----
m("G1", "soc_gpio.v", "assign gpio_oe  = dir_r;", "assign gpio_oe  = out_r;", "GPIO: oe lay tu OUT")
m("G2", "soc_gpio.v", "in_s2 <= in_s1;", "in_s2 <= gpio_in;", "GPIO: dong bo 1 flip-flop")
m("G3", "soc_gpio.v", "(rise & ~edge_r) | (fall & edge_r)", "(fall & ~edge_r) | (rise & edge_r)", "GPIO: canh len va xuong dao")
m("G4", "soc_gpio.v", "pend_r <= (pend_r & ~((wr && addr == 4'd4) ? (wd & wm) : {N{1'b0}})) | ev;", "pend_r <= (pend_r | ev) & ~((wr && addr == 4'd4) ? (wd & wm) : {N{1'b0}});", "GPIO: W1C thang su kien cung chu ky")
m("G5", "soc_gpio.v", "? (wd & wm) : {N{1'b0}}", "? wd : {N{1'b0}}", "GPIO: W1C bo qua byte-lane")
m("G6", "soc_gpio.v", "assign irq      = |(pend_r & ie_r);", "assign irq      = |pend_r;", "GPIO: irq khong che theo IE")
m("G7", "soc_gpio.v", "4'd6: out_r  <= out_r |  (wd & wm);", "4'd6: out_r  <= out_r ^  (wd & wm);", "GPIO: SET thanh TGL")
m("G8", "soc_gpio.v", "4'd7: out_r  <= out_r & ~(wd & wm);", "4'd7: out_r  <= out_r |  (wd & wm);", "GPIO: CLR thanh SET")
m("G9", "soc_gpio.v", "4'd8: out_r  <= out_r ^  (wd & wm);", "4'd8: out_r  <= out_r ^  wd;", "GPIO: TGL bo qua byte-lane")
m("G10", "soc_gpio.v", "4'd0: out_r  <= (out_r  & ~wm) | (wd & wm);", "4'd0: out_r  <= wd;", "GPIO: OUT bo qua byte-lane")
m("G11", "soc_gpio.v", "4'd5: edge_r <= (edge_r & ~wm) | (wd & wm);", "4'd9: edge_r <= (edge_r & ~wm) | (wd & wm);", "GPIO: EDGE khong ghi duoc")
m("G12", "soc_gpio.v", "4'd1:    rdata = {{(32-N){1'b0}}, in_s2};", "4'd1:    rdata = {{(32-N){1'b0}}, in_s1};", "GPIO: IN doc truoc dong bo")
m("G13", "soc_gpio.v", "4'd3: ie_r   <= (ie_r   & ~wm) | (wd & wm);", "4'd3: ie_r   <= wd & wm;", "GPIO: IE ghi byte-lane lam mat byte con lai")
m("G14", "soc_gpio.v", "4'd2:    rdata = {{(32-N){1'b0}}, dir_r};", "4'd2:    rdata = {{(32-N){1'b0}}, out_r};", "GPIO: doc DIR tra OUT")
m("G15", "soc_gpio.v", "4'd4:    rdata = {{(32-N){1'b0}}, pend_r};", "4'd4:    rdata = {{(32-N){1'b0}}, pend_r & ie_r};", "GPIO: doc PEND bi che theo IE")
m("G16", "soc_gpio.v", "wire [N-1:0] fall = ~in_s2 & in_q;", "wire [N-1:0] fall = ~in_s2 & in_s1;", "GPIO: canh xuong so sanh sai thanh ghi")
# ---- SYSCON ----
m("S1", "soc_syscon.v", "3'd0:    rdata = 32'h5256_3C01;", "3'd0:    rdata = 32'h5256_3C00;", "SYSCON: ID sai")
m("S2", "soc_syscon.v", "scratch <= (scratch & ~wmask) | (wdata & wmask);", "scratch <= wdata;", "SYSCON: SCRATCH bo qua byte-lane")
m("S3", "soc_syscon.v", "begin ecode <= wdata; evalid <= 1'b1; end", "begin ecode <= wdata; end", "SYSCON: EXIT khong dat exit_valid")
m("S4", "soc_syscon.v", "begin ecode <= wdata; evalid <= 1'b1; end", "begin evalid <= 1'b1; end", "SYSCON: EXIT khong chot ma")
m("S5", "soc_syscon.v", "berr <= berr + 32'd1;", "berr <= berr + 32'd2;", "SYSCON: BUSERR dem 2")
m("S6", "soc_syscon.v", "else if (bus_err && berr != 32'hFFFF_FFFF)", "else if (bus_err)", "SYSCON: BUSERR khong bao hoa")
m("S7", "soc_syscon.v", "if (wr && addr == 3'd3) berr <= 32'd0;", "if (wr && addr == 3'd2) berr <= 32'd0;", "SYSCON: xoa BUSERR sai dia chi")
m("S8", "soc_syscon.v", "if (wr && addr == 3'd3) berr <= 32'd0;\n            else if (bus_err && berr != 32'hFFFF_FFFF) berr <= berr + 32'd1;",
  "if (bus_err && berr != 32'hFFFF_FFFF) berr <= berr + 32'd1;\n            else if (wr && addr == 3'd3) berr <= 32'd0;", "SYSCON: dem thang xoa cung chu ky")
# ---- TOP ----
m("T1", "soc_top.v", ".src({ext_irq, irq_gpio, irq_uart_tx, irq_uart_rx})", ".src({ext_irq, 1'b0, irq_uart_tx, irq_uart_rx})", "top: ngat GPIO khong toi loi")
m("T2", "soc_top.v", ".src({ext_irq, irq_gpio, irq_uart_tx, irq_uart_rx})", ".src({ext_irq, irq_gpio, 1'b0, 1'b0})", "top: ngat UART khong toi loi")
m("T3", "soc_top.v", ".irq_timer(irq_timer), .irq_soft(irq_soft), .irq_ext(irq_ext)", ".irq_timer(irq_soft), .irq_soft(irq_timer), .irq_ext(irq_ext)", "top: ngat timer va phan mem dao")
m("T4", "soc_top.v", "rv32im_pipeline #(.ENABLE_C(1))", "rv32im_pipeline #(.ENABLE_C(0))", "top: tat lenh nen C")
m("T5", "soc_top.v", ".sel(sel_uart), .addr(dmem_addr[4:2]), .we(dmem_we), .re(dmem_re)", ".sel(sel_uart), .addr(dmem_addr[4:2]), .we(dmem_we), .re(1'b1)", "top: UART re luon bat")
m("T6", "soc_top.v", "assign imem_data = i_sel_rom ? rom_idata : i_sel_ram ? ram_idata : 32'd0;", "assign imem_data = i_sel_rom ? rom_idata : ram_idata;", "top: fetch ngoai ROM")
m("T7", "soc_top.v", ".sel(sel_gpio), .addr(dmem_addr[5:2]), .we(dmem_we), .wstrb(dmem_wstrb),", ".sel(sel_gpio), .addr(dmem_addr[5:2]), .we(dmem_we), .wstrb(4'b0001),", "top: GPIO chi nhan byte 0")
m("T8", "soc_top.v", ".DEFAULT_DIV(UART_DIV)", ".DEFAULT_DIV(16'd20)", "top: DIV mac dinh khong theo tham so")
m("T9", "soc_top.v", ".sel(sel_ram), .addr(dmem_addr)", ".sel(1'b1), .addr(dmem_addr)", "top: RAM luon duoc chon")
m("T10", "soc_top.v", ".bus_err(bus_err), .exit_valid(exit_valid)", ".bus_err(1'b0), .exit_valid(exit_valid)", "top: BUSERR khong noi")
m("T11", "soc_top.v", ".sel(sel_clint), .addr(dmem_addr[4:2])", ".sel(sel_clint), .addr(dmem_addr[5:3])", "top: CLINT sai bit dia chi")
m("T12", "soc_top.v", "wire sel_rom, sel_ram, sel_clint, sel_uart, sel_gpio, sel_sys, i_sel_rom, i_sel_ram, bus_err;", "wire sel_rom, sel_ram, sel_clint, sel_uart, sel_gpio, sel_sys, i_sel_rom, i_sel_ram, bus_err; wire dummy_m = 1'b0;", "(kiem tra nguoc: dot bien vo hai, KHONG duoc tinh)")
# ---- LOI: sua mepc (bit 1 cua mepc voi lenh nen) ----
m("C1", "../rv32im_pipeline.v", "tepc_q       <= idex_pc[31:1];", "tepc_q       <= {idex_pc[31:2], 1'b0};", "loi: mepc bo bit 1 khi trap")
m("C2", "../rv32im_pipeline.v", "mret_ex ? mepc_v           :\n                         fencei_ex ? pc_next :", "mret_ex ? {mepc_r[31:2], 2'b00} :\n                         fencei_ex ? pc_next :", "loi: MRET bo bit 1 cua mepc")
m("C3", "../rv32im_pipeline.v", "12'h341: csr_rdata = mepc_v;", "12'h341: csr_rdata = {mepc_r[31:2], 2'b00};", "loi: doc mepc bo bit 1")
m("C4", "../rv32im_pipeline.v", "12'h341: mepc_r   <= csr_new[31:1];", "12'h341: mepc_r   <= {csr_new[31:2], 1'b0};", "loi: ghi mepc bo bit 1")

EQUIV_CHECK = {"T12"}   # dot bien vo hai co y: phai LOT (de kiem tra bo kiem chung khong bao dong gia)


def apply(tmp, mut):
    i, f, old, new, d = mut
    path = os.path.join(tmp, "soc", f) if not f.startswith("..") else os.path.join(tmp, f[3:])
    s = open(path).read()
    if s.count(old) != 1:
        return "old xuat hien %d lan" % s.count(old)
    open(path, "w").write(s.replace(old, new))
    return None


def run_one(mut, sw):
    tmp = tempfile.mkdtemp(prefix="mut_")
    try:
        shutil.copytree(os.path.join(ROOT, "soc"), os.path.join(tmp, "soc"), ignore=shutil.ignore_patterns("sw", "__pycache__"))
        for f in run_soc.CORE:
            shutil.copy(os.path.join(ROOT, f), tmp)
        err = apply(tmp, mut)
        if err:
            return (mut, "LOI", err)
        res = run_soc.run_suite(tmp, sw, tmp, stop_first=True, verbose=False)
        bad = [r for r in res if not r[1]]
        if not bad:
            return (mut, "LOT", "")
        if "bien dich" in bad[0][0] or "loi bien dich" in bad[0][2]:
            return (mut, "LOI", "khong bien dich: " + bad[0][2])
        return (mut, "BAT", bad[0][0])
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 2)
    ap.add_argument("--only", default="")
    a = ap.parse_args()
    sw = os.path.join(run_soc.HERE, "sw", "build")
    muts = [x for x in M if a.only in x[0] or a.only in x[4]]
    print("[mutate-soc] %d dot bien, %d luong" % (len(muts), a.jobs), flush=True)
    caught, missed, errors, by = 0, [], [], {}
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for k, (mut, st, info) in enumerate(ex.map(lambda x: run_one(x, sw), muts), 1):
            i, f, old, new, d = mut
            if i in EQUIV_CHECK:
                ok = (st == "LOT")
                print("[%3d/%d] %-5s %s: %s -> %s %s" % (k, len(muts), i, "dot bien vo hai", d, "lot (dung)" if ok else st, info), flush=True)
                if not ok:
                    errors.append((i, "dot bien vo hai khong duoc lot: " + st))
                continue
            if st == "BAT":
                caught += 1; by[info] = by.get(info, 0) + 1
            elif st == "LOT":
                missed.append((i, d))
            else:
                errors.append((i, info))
            print("[%3d/%d] %-5s %-48s %s %s" % (k, len(muts), i, d[:48], st, info), flush=True)
    real = len(muts) - sum(1 for x in muts if x[0] in EQUIV_CHECK)
    print("[mutate-soc] bat %d / %d dot bien" % (caught, real))
    print("[mutate-soc] bat boi:", ", ".join("%s %d" % kv for kv in sorted(by.items(), key=lambda kv: -kv[1])))
    for i, d in missed:
        print("[mutate-soc] LOT:", i, d)
    for i, e in errors:
        print("[mutate-soc] LOI:", i, e)
    sys.exit(0 if not missed and not errors else 1)


if __name__ == "__main__":
    main()
