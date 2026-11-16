# VoxCore simulation (Verilator 5.x). Run from this directory.
#   make mfcc        MFCC block test, 10 clips, bit-exact vs Python
#   make nn          NN accelerator block test, 10 clips
#   make mac         VC.MAC unit, 20k constrained-random ops + coverage
#   make isa         37 rv32ui ISA tests on vc_rv32i (+ with 50% bus wait states) and PicoRV32
#   make rand        300 random programs, vc_rv32i retirement trace vs Python ISS
#   make perf        branch-predictor performance test (misprediction budget)
#   make aes         AES-128 peripheral: NIST known answers + 1000 blocks vs Python, security rules
#   make aes_mut     mutation check: tb_aes must FAIL on each injected AES bug
#   make pdm         mixed-signal block test: analog sigma-delta RNM + PDM decimator, bit-exact
#   make soc_pdm     full SoC with the PDM microphone path, one clip (make soc_pdm CLIP=3)
#   make pdm_nonideal A=20   PDM block sim with a finite-gain op-amp (NOISE=1e-4 adds kT/C noise)
#   make soc         full SoC on vc_rv32i, one clip   (make soc CLIP=3)
#   make soc_pico    full SoC on PicoRV32, one clip
#   make regress     everything above, all clips, both CPUs
#   make lint        Verilator lint of the synthesizable RTL
VFLAGS = --binary --timing -j 8 +incdir+../data \
         -Wno-fatal -Wno-WIDTH -Wno-UNUSED -Wno-TIMESCALEMOD -Wno-INITIALDLY \
         -Wno-PINCONNECTEMPTY -Wno-CASEINCOMPLETE -Wno-UNOPTFLAT
MEM   = ../rtl/mem/vc_rom.sv ../rtl/mem/vc_sram_1p.sv ../rtl/mem/vc_sram_2p.sv \
        ../rtl/mem/vc_sram_bw.sv ../rtl/mem/vc_sram_dp_bw.sv
CORE  = ../rtl/mfcc_engine.sv ../rtl/nn_engine.sv
CPU   = ../rtl/cpu/vc_rv32i.sv ../rtl/cpu/vc_mac_pcpi.sv ../rtl/third_party/picorv32/picorv32.v
AES   = ../rtl/periph/aes128_enc.sv ../rtl/periph/aes_apb.sv
SOC   = $(CPU) $(AES) ../rtl/periph/i2s_rx.sv ../rtl/periph/pdm_rx.sv ../rtl/periph/uart_apb.sv \
        ../rtl/periph/gpio_apb.sv ../rtl/soc/apb_bridge.sv ../rtl/voice_apb.sv ../rtl/voxcore_top.sv
CLIP ?= 0
SRC   = $(filter %.sv %.v,$^)

obj_mfcc/Vtb_mfcc: $(MEM) $(CORE) ../tb/tb_mfcc.sv
	verilator $(VFLAGS) --top-module tb_mfcc -Mdir obj_mfcc $(SRC)
obj_nn/Vtb_nn: $(MEM) $(CORE) ../tb/tb_nn.sv
	verilator $(VFLAGS) --top-module tb_nn -Mdir obj_nn $(SRC)
obj_pdm/Vtb_pdm: ../rtl/mem/vc_rom.sv ../rtl/mem/vc_sram_2p.sv ../rtl/periph/pdm_rx.sv ../rtl/ams/sdm_rnm.sv ../tb/tb_pdm.sv
	verilator $(VFLAGS) --top-module tb_pdm -Mdir obj_pdm $(SRC)
obj_mac/Vtb_mac: ../rtl/cpu/vc_mac_pcpi.sv ../tb/tb_mac.sv
obj_aes/Vtb_aes: $(AES) ../tb/tb_aes.sv ../data/aes_vectors.hex
	verilator $(VFLAGS) --top-module tb_aes -Mdir obj_aes $(SRC)
../data/aes_vectors.hex: ../model/aes_model.py
	python3 ../model/aes_model.py selftest
	python3 ../model/aes_model.py sbox ../data/aes_sbox.svh
	python3 ../model/aes_model.py vectors $@ 1000 1
	verilator $(VFLAGS) --top-module tb_mac -Mdir obj_mac $(SRC)
obj_core_vc/Vtb_core: $(CPU) ../tb/tb_core.sv
	verilator $(VFLAGS) --top-module tb_core -GCPU_SEL=0 -Mdir obj_core_vc $(SRC)
obj_core_pico/Vtb_core: $(CPU) ../tb/tb_core.sv
	verilator $(VFLAGS) --top-module tb_core -GCPU_SEL=1 -Mdir obj_core_pico $(SRC)
obj_soc/Vtb_soc: $(MEM) $(CORE) $(SOC) ../rtl/ams/sdm_rnm.sv ../tb/tb_soc.sv ../fw/firmware.hex
	verilator $(VFLAGS) --top-module tb_soc -GCPU_SEL=0 -Mdir obj_soc $(SRC)
obj_soc_pico/Vtb_soc: $(MEM) $(CORE) $(SOC) ../rtl/ams/sdm_rnm.sv ../tb/tb_soc.sv ../fw/firmware.hex
	verilator $(VFLAGS) --top-module tb_soc -GCPU_SEL=1 -Mdir obj_soc_pico $(SRC)

../fw/firmware.hex: ../fw/main.c ../fw/start.S ../fw/link.ld ../fw/vc_mac.h
	$(MAKE) -C ../fw

mfcc: obj_mfcc/Vtb_mfcc ; ./$< | tee mfcc.log
nn:   obj_nn/Vtb_nn     ; ./$< | tee nn.log
mac:  obj_mac/Vtb_mac   ; ./$< | tee mac.log
aes:  obj_aes/Vtb_aes   ; ./$< | tee aes.log
aes_mut: $(AES) ../tb/tb_aes.sv ../data/aes_vectors.hex
	@for b in AES_BUG_RCON AES_BUG_LASTMIX; do \n	  verilator $(VFLAGS) -D$$b --top-module tb_aes -Mdir obj_aes_$$b $(SRC) > /dev/null && \n	  if ./obj_aes_$$b/Vtb_aes | grep -q "tb_aes FAILED"; then echo "$$b: caught"; else echo "$$b: NOT CAUGHT"; exit 1; fi; \n	done; echo "==== aes_mut PASSED ===="
pdm:  obj_pdm/Vtb_pdm   ; ./$< | tee pdm.log
	@python3 -c "import sys; sys.path.insert(0,'../model'); import numpy as np, pdm_model as pm; \
	  s,e = pm.snr_enob(np.loadtxt('pdm_sine_rtl.txt')[256:], f0=1000.0, band=(20,6400)); \
	  print(f'RTL PDM path: SNR {s:.1f} dB, ENOB {e:.2f} (1 kHz, -6 dBFS)')" | tee -a pdm.log
isa:  obj_core_vc/Vtb_core obj_core_pico/Vtb_core
	{ echo "[vc_rv32i, no waits]";  ../verif/isa/run_isa.sh obj_core_vc/Vtb_core 0;  \
	  echo "[vc_rv32i, 50% waits]"; ../verif/isa/run_isa.sh obj_core_vc/Vtb_core 50; \
	  echo "[picorv32]";            ../verif/isa/run_isa.sh obj_core_pico/Vtb_core 0; } 2>&1 | tee isa.log
rand: obj_core_vc/Vtb_core
	../verif/rand/run_rand.sh obj_core_vc/Vtb_core 300 500 2>&1 | tee rand.log
../verif/perf/bpred.hex: ../verif/perf/bpred.S
	cd ../verif/perf && riscv64-unknown-elf-gcc -march=rv32i -mabi=ilp32 -nostdlib -nostartfiles \
	  -T ../isa/link.ld bpred.S -o bpred.elf && riscv64-unknown-elf-objcopy -O binary bpred.elf bpred.bin && \
	  python3 ../../fw/bin2hex.py bpred.bin bpred.hex 16384
perf: obj_core_vc/Vtb_core ../verif/perf/bpred.hex
	./obj_core_vc/Vtb_core +HEX=../verif/perf/bpred.hex +MAXMISS=210 | grep -E "BPRED|HALT" | tee perf.log
	@grep -q "OK" perf.log && ! grep -q "PERF-FAIL" perf.log && echo "==== perf PASSED ====" | tee -a perf.log || \
	  { echo "==== perf FAILED ====" | tee -a perf.log; false; }
soc:      obj_soc/Vtb_soc      ; ./$< +CLIP=$(CLIP) | tee soc_clip$(CLIP).log
soc_pico: obj_soc_pico/Vtb_soc ; ./$< +CLIP=$(CLIP) | tee soc_pico_clip$(CLIP).log
soc_pdm:  obj_soc/Vtb_soc      ; ./$< +CLIP=$(CLIP) +SRC=PDM | tee soc_pdm_clip$(CLIP).log
A ?= 0.0
NOISE ?= 0.0
pdm_nonideal: ../rtl/mem/vc_rom.sv ../rtl/mem/vc_sram_2p.sv ../rtl/periph/pdm_rx.sv ../rtl/ams/sdm_rnm.sv ../tb/tb_pdm.sv
	verilator $(VFLAGS) --top-module tb_pdm -GOPAMP_GAIN=$(A) -GNOISE_RMS=$(NOISE) -Mdir obj_pdm_ni $^
	./obj_pdm_ni/Vtb_pdm | head -2
	@python3 -c "import sys; sys.path.insert(0,'../model'); import numpy as np, pdm_model as pm; \
	  s,e = pm.snr_enob(np.loadtxt('pdm_sine_rtl_nonideal.txt')[256:], f0=1000.0, band=(20,6400)); \
	  print(f'RTL PDM path, op-amp gain A=$(A), noise=$(NOISE): SNR {s:.1f} dB, ENOB {e:.2f}')"

regress: obj_mfcc/Vtb_mfcc obj_nn/Vtb_nn obj_mac/Vtb_mac obj_aes/Vtb_aes obj_pdm/Vtb_pdm obj_core_vc/Vtb_core obj_core_pico/Vtb_core \
         obj_soc/Vtb_soc obj_soc_pico/Vtb_soc
	./obj_mfcc/Vtb_mfcc | tee mfcc.log
	./obj_nn/Vtb_nn | tee nn.log
	./obj_mac/Vtb_mac | tee mac.log
	./obj_aes/Vtb_aes | tee aes.log
	$(MAKE) --no-print-directory pdm isa rand perf
	for c in 0 1 2 3 4 5 6 7 8 9; do ./obj_soc/Vtb_soc +CLIP=$$c | tee soc_clip$$c.log; done
	for c in 0 1 2 3 4 5 6 7 8 9; do ./obj_soc_pico/Vtb_soc +CLIP=$$c | tee soc_pico_clip$$c.log; done
	for c in 0 1 2 3 4 5 6 7 8 9; do ./obj_soc/Vtb_soc +CLIP=$$c +SRC=PDM | tee soc_pdm_clip$$c.log; done
	@echo; echo "==== REGRESSION SUMMARY ===="
	@grep -h "====" mfcc.log nn.log mac.log aes.log pdm.log perf.log soc_clip*.log soc_pico_clip*.log soc_pdm_clip*.log
	@grep -h "RTL PDM path" pdm.log
	@grep -h "ISA tests\|Random tests" isa.log rand.log

lint:
	verilator --lint-only -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY +incdir+../data \
	  --top-module voxcore_top $(MEM) $(CORE) $(SOC) 2>&1 | grep -v picorv32 | grep -E "^%(Error|Warning)" | sort | uniq -c | sort -rn | head -40

clean:
	rm -rf obj_* *.log pdm_sine_rtl*.txt ../verif/isa/build ../verif/rand/build ../verif/perf/bpred.elf ../verif/perf/bpred.bin
.PHONY: mfcc nn mac aes aes_mut pdm pdm_nonideal isa rand perf soc soc_pico soc_pdm regress lint clean
