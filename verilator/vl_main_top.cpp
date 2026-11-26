// main chung cho Verilator (cac testbench khac tb_cosim): VTOP = ten lop mo hinh (vd. Vtb_cache_random), VTOPH = tep header.
// Verilator 5.020 --binary khong tu ghi coverage nen main nay ghi coverage.dat (thu muc chay) khi ket thuc mo phong.
#include VTOPH
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

int main(int argc, char** argv, char**) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<VTOP> topp{new VTOP{contextp.get()}};
    while (!contextp->gotFinish()) {
        topp->eval();
        if (!topp->eventsPending()) break;
        contextp->time(topp->nextTimeSlot());
    }
    topp->final();
    contextp->coveragep()->write("coverage.dat");
    return 0;
}
