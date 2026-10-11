# Kiểm chứng lõi RV32I

So sánh từng lệnh của RTL với một mô hình tham chiếu viết độc lập bằng Python, trên hàng trăm chương trình ngẫu nhiên.

## Thành phần
| File | Nội dung |
|---|---|
| `rv32i_iss.py` | Mô hình tham chiếu (ISS), in vết mỗi lệnh |
| `tb_trace.v` | Testbench in vết của RTL cùng định dạng (`+prog=`, `+dmem=`) |
| `gen_prog.py` | Sinh chương trình ngẫu nhiên hợp lệ (nhánh chỉ nhảy tới, truy cập bộ nhớ căn chỉnh, khởi tạo đủ thanh ghi) |
| `run_verify.py` | Chạy so sánh, đo độ phủ lệnh, kiểm tra bằng đột biến lỗi |

## Dùng
Cần `python3` và `iverilog`. Chạy trong thư mục `verify/` của repo (file `../rv32i_core.v` và `../prog.hex` phải có):
```
python3 run_verify.py                  # 200 chương trình ngẫu nhiên + chương trình định hướng
python3 run_verify.py --n 500 --len 400
python3 run_verify.py --mutate         # chèn lỗi cố ý, kiểm tra bộ kiểm chứng có bắt được
```
Kết quả kỳ vọng: `that bai: 0` và `du 37/37 lenh`.

## Định dạng vết
```
pc=00000000 ins=40000093 rd=1 val=00000400 st=0 addr=00000000 data=00000000 strb=0
```
Mỗi dòng là một lệnh đã thực thi: `rd`/`val` là thanh ghi đích và giá trị ghi (0 nếu không ghi), `st`/`addr`/`data`/`strb` là lần ghi bộ nhớ (data đã che theo byte-enable).
Khi đổi sang pipeline, chỉ cần `tb_trace.v` in vết ở tầng commit theo cùng định dạng, ISS và bộ sinh dùng lại nguyên.

## Giới hạn
- ISS và RTL do cùng một người viết, nên hiểu sai đặc tả ở cả hai bên sẽ không bị phát hiện. Muốn chắc hơn thì đối chiếu thêm với Spike hoặc bộ `riscv-tests` chính thức.
- Chưa phủ: truy cập không căn chỉnh, ngoại lệ (trap), CSR, FENCE.
- Chương trình ngẫu nhiên không có vòng lặp (nhánh chỉ nhảy tới); vòng lặp được thử trong `prog.hex` định hướng.
