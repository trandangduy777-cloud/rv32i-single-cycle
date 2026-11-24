// main cho Verilator (dung voi cosim/run_vlcov.py): giong main cua --binary nhung ghi file coverage khi ket thuc mo phong
// (Verilator 5.020 --binary khong tu ghi coverage.dat)
#include "Vtb_cosim.h"
#include "verilated.h"
#include "verilated_cov.h"
#include <memory>

int main(int argc, char** argv, char**) {
    const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
    contextp->commandArgs(argc, argv);
    const std::unique_ptr<Vtb_cosim> topp{new Vtb_cosim{contextp.get()}};
    while (!contextp->gotFinish()) {
        topp->eval();
        if (!topp->eventsPending()) break;
        contextp->time(topp->nextTimeSlot());
    }
    topp->final();
    contextp->coveragep()->write("coverage.dat");
    return 0;
}
