# Kiểm chứng lõi RV32I

So sánh từng lệnh của RTL với một mô hình tham chiếu viết độc lập bằng Python, trên hàng trăm chương trình ngẫu nhiên (có CSR, trap, lệnh bất hợp lệ).

## Thành phần
| File | Nội dung |
|---|---|
| `rv32i_iss.py` | Mô hình tham chiếu (ISS), in vết mỗi lệnh |
| `tb_trace_pipe.v` | Như trên nhưng đọc tầng WB của pipeline |
| `tb_trace.v` | Testbench in vết của RTL cùng định dạng (`+prog=`, `+dmem=`), chỉ in khi lệnh hoàn tất (`retire`) |
| `gen_prog.py` | Sinh chương trình ngẫu nhiên (nhánh chỉ nhảy tới, truy cập bộ nhớ căn chỉnh, khởi tạo đủ thanh ghi, có CSR/trap và bộ xử lý trap ở `0xC00`) |
| `run_verify.py` | Chạy so sánh, đo độ phủ lệnh, kiểm tra bằng đột biến lỗi |

## Dùng
Cần `python3` và `iverilog`. Chạy trong thư mục `verify/` của repo (file `../rv32i_core.v` và `../prog.hex` phải có):
```
python3 run_verify.py                  # 200 chương trình ngẫu nhiên + chương trình định hướng
python3 run_verify.py --n 500 --len 400
python3 run_verify.py --mutate         # 42 lỗi chèn cố ý, kiểm tra bộ kiểm chứng có bắt được
```
Kiểm chứng pipeline (chỉ RV32I thuần, in vết ở tầng WB bằng `tb_trace_pipe.v`):
```
python3 run_verify.py --pipe                   # 200 chương trình ngẫu nhiên + chương trình định hướng
python3 run_verify.py --pipe --mutate          # 28 lỗi hazard/forwarding/flush/dự đoán nhánh chèn cố ý
```
Pipeline đầy đủ (RV32IM + CSR + trap; chương trình ngẫu nhiên có thêm đọc/ghi `mie`, `mip`, chân ngắt nối 0, ngắt được kiểm riêng trong `../irq/`):
```
python3 run_verify.py --pipem
python3 run_verify.py --pipem --mutate         # 66 lỗi chèn cố ý (hazard, CSR, trap, M, flush, redirect đăng ký)
```
Chương trình ngẫu nhiên ưu tiên một nhóm thanh ghi nhỏ (x0, x2..x5) để các lệnh sát nhau hay phụ thuộc dữ liệu, nhờ đó forwarding và load-use được thử nhiều.

Kết quả kỳ vọng: `that bai: 0`, `Phu lenh: 55/55`, `Phu truong hop bien chia: ... | du`, `du 6 loai trap`. Mutation test chạy lâu hơn (5-15 phút), kỳ vọng bắt được toàn bộ: `Bat duoc 42/42` (single-cycle), `28/28` (`--pipe`), `66/66` (`--pipem`). Có thể chạy riêng một nhóm lỗi bằng `--only`, ví dụ `--mutate --only "M:"`. Mutation nào không còn tìm thấy chuỗi cần đổi trong RTL được báo `BO QUA` và tính là thất bại, để không âm thầm bỏ qua khi RTL thay đổi.

## Định dạng vết
```
pc=00000000 ins=40000093 rd=1 val=00000400 st=0 addr=00000000 data=00000000 strb=0
```
Mỗi dòng là một lệnh đã thực thi: `rd`/`val` là thanh ghi đích và giá trị ghi (0 nếu không ghi), `st`/`addr`/`data`/`strb` là lần ghi bộ nhớ (data đã che theo byte-enable).
Pipeline dùng lại nguyên ISS và bộ sinh (profile `base`), chỉ khác testbench in vết ở tầng WB theo cùng định dạng.

## Giới hạn
- ISS và RTL do cùng một người viết, nên hiểu sai đặc tả ở cả hai bên sẽ không bị phát hiện. Muốn chắc hơn thì đối chiếu thêm với Spike hoặc bộ `riscv-tests` chính thức.
- Chưa phủ: truy cập load/store không căn chỉnh, ngắt.
- Bộ xử lý trap trong chương trình ngẫu nhiên luôn quay lại lệnh kế tiếp (`mepc + 4`), nên chỉ kiểm tra trap theo kiểu "bỏ qua lệnh gây lỗi".
- Chương trình ngẫu nhiên không có vòng lặp (nhánh chỉ nhảy tới); vòng lặp được thử trong `prog.hex` định hướng.

- Mutation test coi mutation bị bỏ qua (không tìm thấy chuỗi cần thay trong RTL) là thất bại. Khi sửa RTL, cập nhật chuỗi trong `MUTATIONS` cho khớp.
- Testbench in vết dừng sau 20.000 chu kỳ (`TIMEOUT`) để chặn vòng lặp vô hạn khi có lỗi.
