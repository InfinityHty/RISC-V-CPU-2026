# A/B-side directed unit tests

These testbenches are **not** part of `verilog/ooo/filelist.f` and are not built by
`make`. They cover the ordered front end and the execution/memory modules.

Run them inside the course AppImage so the bundled Verilator is used:

```sh
# decode
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_decode --top-module tb_decode \
   -o /tmp/tb_decode verilog/ooo/cpu_pkg.sv verilog/ooo/decode.sv \
   verilog/ooo/tb/tb_decode.sv && /tmp/tb_decode'

# rename + ROB + PRF + flush/checkpoint
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_core --top-module tb_core \
   -o /tmp/tb_core verilog/ooo/cpu_pkg.sv verilog/ooo/decode.sv \
   verilog/ooo/prf.sv verilog/ooo/rename.sv verilog/ooo/rob.sv \
   verilog/ooo/tb/tb_core.sv && /tmp/tb_core'

# IFU (direct fake AXI, sequential + flush)
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_ifu --top-module tb_ifu \
   -o /tmp/tb_ifu verilog/ooo/cpu_pkg.sv verilog/ooo/ifu.sv \
   verilog/ooo/tb/tb_ifu.sv && /tmp/tb_ifu'

# branch predictor
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_bpred --top-module tb_bpred \
   -o /tmp/tb_bpred verilog/ooo/cpu_pkg.sv verilog/ooo/bpred.sv \
   verilog/ooo/tb/tb_bpred.sv && /tmp/tb_bpred'

# I-Cache (with framework sram_fakeram model)
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_icache --top-module tb_icache \
   -o /tmp/tb_icache verilog/ooo/cpu_pkg.sv verilog/ooo/icache.sv \
   scripts/ram/sram_fakeram.sv verilog/ooo/tb/tb_icache.sv && /tmp/tb_icache'

# IFU + bpred prediction path (taken prediction jumps to target)
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_ifu_pred --top-module tb_ifu_pred \
   -o /tmp/tb_ifu_pred verilog/ooo/cpu_pkg.sv verilog/ooo/bpred.sv \
   verilog/ooo/ifu.sv verilog/ooo/tb/tb_ifu_pred.sv && /tmp/tb_ifu_pred'

# IFU + bpred + I-Cache integration
./cpu2026-tools-x86_64.AppImage exec sh -c \
  '"$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
   --Mdir /tmp/obj_tb_frontend --top-module tb_frontend \
   -o /tmp/tb_frontend verilog/ooo/cpu_pkg.sv verilog/ooo/bpred.sv \
   verilog/ooo/ifu.sv verilog/ooo/icache.sv scripts/ram/sram_fakeram.sv \
   verilog/ooo/tb/tb_frontend.sv && /tmp/tb_frontend'
```

B-side tests (run sequentially in one AppImage process):

```sh
./cpu2026-tools-x86_64.AppImage exec sh -c '
  set -e
  for tb in alu rs cdb muldiv axi_master lsu; do
    mkdir -p "build/tb_${tb}"
    rm -rf "build/tb_${tb}/obj"
    "$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
      --Mdir "build/tb_${tb}/obj" --top-module "tb_${tb}" \
      -o "$PWD/build/tb_${tb}/sim" verilog/ooo/cpu_pkg.sv \
      "verilog/ooo/${tb}.sv" "verilog/ooo/tb/tb_${tb}.sv"
    "build/tb_${tb}/sim"
  done
  tb=dcache
  mkdir -p "build/tb_${tb}"
  rm -rf "build/tb_${tb}/obj"
  "$APPDIR/bin/verilator" --binary --timing -Wno-fatal -Wno-lint \
    --Mdir "build/tb_${tb}/obj" --top-module "tb_${tb}" \
    -o "$PWD/build/tb_${tb}/sim" verilog/ooo/cpu_pkg.sv \
    "verilog/ooo/${tb}.sv" scripts/ram/sram_fakeram.sv \
    "verilog/ooo/tb/tb_${tb}.sv"
  "build/tb_${tb}/sim"
'
```

Expected output:

```text
TB_DECODE_PASS
TB_CORE_PASS phase1+phase2+phase3 commits=128
TB_IFU_PASS
TB_IFU_PRED_PASS
TB_BPRED_PASS
TB_ICACHE_PASS
TB_FRONTEND_PASS
TB_ALU_PASS
TB_RS_PASS
TB_CDB_PASS
TB_MULDIV_PASS
TB_AXI_MASTER_PASS
TB_LSU_PASS
TB_DCACHE_PASS
```