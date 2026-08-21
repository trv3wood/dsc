.PHONY: test test-full official-regression golden images model model-clean model-run model-4k \
	model-regression model-regression-full model-compile-commands rtl-clean \
	rtl-regression rtl-regression-full rtl-top rtl-top-trace rtl-top-cov \
	rtl-top-cov-clean rtl-top-multi rtl-flatness-replay rtl-formal \
	rtl-formal-prove rtl-formal-cover rtl-lint rtl-slang rtl-smoke

GOLDEN_SEED ?= 0x445343
GOLDEN_PATTERN ?= random
BLOCK_PRED ?= 1
REGRESSION_PARALLEL ?= 2
OFFICIAL_ARCHIVE ?= $(HOME)/Work/dsc/Display\ Stream\ Compression\ \(DSC\)\ Test\ Results-selected.zip
VERILATOR_WARNINGS := -Wall -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
	-Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY -Wno-BLKSEQ -Wno-DECLFILENAME \
	-Wno-GENUNNAMED -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD
VERILATOR_COMMON := --binary --timing --assert $(VERILATOR_WARNINGS)

test: rtl-lint rtl-smoke rtl-regression model-regression

test-full: rtl-regression-full model-regression-full

# 使用 VESA 官方主观测试图，由冻结 C model 生成 golden 后对拍 RTL。
official-regression:
	python3 tools/run_rtl_regression.py --profile official --official-archive $(OFFICIAL_ARCHIVE)

golden:
	python3 tests/verilator/generate_golden.py --seed $(GOLDEN_SEED) --pattern $(GOLDEN_PATTERN) --block-pred $(BLOCK_PRED)

images:
	python3 tools/generate_test_images.py

model:
	$(MAKE) -C model/src

model-clean:
	$(MAKE) -C model/src clean

model-run: images model
	cd model/config && ../src/dsc -F test.cfg

model-4k: images model
	python3 tools/generate_test_images.py --width 3840 --height 2160 --output model/testdata4k --list-output model/config/test_list_4k.txt
	cd model/config && ../src/dsc -F test_4k.cfg
	cd model/config && ../src/dsc -F test_4k_dec.cfg

model-regression: model
	python3 tools/run_dsc_regression.py --profile quick --parallel $(REGRESSION_PARALLEL)

model-regression-full: model
	python3 tools/run_dsc_regression.py --profile full --parallel $(REGRESSION_PARALLEL)

rtl-regression:
	python3 tools/run_rtl_regression.py --profile quick

rtl-regression-full:
	python3 tools/run_rtl_regression.py --profile full

# 用 bear 拦截 model 构建，生成 compile_commands.json 供 clangd LSP 使用。
# clean 强制重编，确保 bear 记录到全部编译命令。
model-compile-commands:
	bear -- make -C model/src clean dsc

rtl-lint:
	verilator --lint-only --timing -Wall -Wno-fatal \
		--top-module dsc_encoder -f tests/verilator/rtl.f

rtl-slang:
	slang --std 1800-2017 --top dsc_encoder -f tests/verilator/rtl.f

rtl-smoke:
	verilator $(VERILATOR_COMMON) \
		--top-module tb_dsc_encoder -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_encoder.sv
	./obj_dir/Vtb_dsc_encoder

rtl-top: golden
	verilator $(VERILATOR_COMMON) \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv
	./obj_dir/Vtb_dsc_e2e

# 同 rtl-top，但启用 VCD 波形 dump（DSC_VCD_DUMP 由 tb 在 ifdef 内开启），供 gtkwave 查看。
rtl-top-trace: golden
	verilator $(VERILATOR_COMMON) -DDSC_VCD_DUMP \
		--trace --trace-depth 5 \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv
	./obj_dir/Vtb_dsc_e2e
	@echo "VCD 波形已生成: tests/verilator/generated/rtl_e2e_trace.vcd"
	@echo "用 gtkwave 打开: gtkwave tests/verilator/generated/rtl_e2e_trace.vcd"

# 覆盖率分析（line + toggle）。产物全部输出到 $(COV_DIR)（默认 /tmp/dsc_cov），
# 不污染工作区；用 verilator_coverage --annotate 生成逐行注释报告。
# 看盲区: grep '%000000' $(COV_DIR)/annotate/dsce_*.sv
COV_DIR ?= /tmp/dsc_cov
FORMAL_DIR ?= /tmp/dsc_formal

rtl-top-cov: golden
	mkdir -p $(COV_DIR)
	verilator $(VERILATOR_COMMON) \
		--coverage-line --coverage-toggle --coverage-underscore \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv --Mdir $(COV_DIR)/obj
	$(COV_DIR)/obj/Vtb_dsc_e2e +verilator+coverage+file+$(COV_DIR)/coverage.dat
	verilator_coverage $(COV_DIR)/coverage.dat --annotate $(COV_DIR)/annotate
	@echo "覆盖率产物: $(COV_DIR)/"
	@echo "模块盲区排名: 见 verilator_coverage 上方 Total coverage 行"
	@echo "看具体未覆盖行: grep '%000000' $(COV_DIR)/annotate/dsce_*.sv"

rtl-top-cov-clean:
	rm -rf $(COV_DIR)

# 多 slice / 多分辨率 top。向量由 generate_golden.py 生成；MULTI_CASE 指定用例名
#（如 ms2、ms2_192；缺省读 generated/ 单 slice）。多 slice 交织缺陷见 rtl_fix_log.md。
rtl-top-multi: golden
	verilator $(VERILATOR_COMMON) \
		--top-module tb_dsc_e2e_multi -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e_multi.sv --Mdir obj_multi
	./obj_multi/Vtb_dsc_e2e_multi $(if $(MULTI_CASE),+case=$(MULTI_CASE),)

# 用独立像素/QP function model 逐事务验证 flatness 边界，不经过预测器和码控。
rtl-flatness-replay:
	$(MAKE) golden GOLDEN_PATTERN=flatness
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-BLKSEQ -Wno-TIMESCALEMOD \
		--top-module tb_dsc_flatness_replay \
		verilog_dsc/dsce_defs_pkg.sv verilog_dsc/dsce_flat_check.sv \
		verilog_dsc/dsce_flat_flags.sv verilog_dsc/dsce_flatness.sv \
		tests/verilator/tb_dsc_flatness_replay.sv
	./obj_dir/Vtb_dsc_flatness_replay

# 证明安全 flush 契约，并生成当前跨 slice 清空行为的最短反例轨迹。
rtl-formal: rtl-formal-prove rtl-formal-cover

rtl-formal-prove:
	sby -f -d $(FORMAL_DIR)/flatness_fifo_prove \
		tests/formal/flatness_transaction_fifo.sby prove

rtl-formal-cover:
	sby -f -d $(FORMAL_DIR)/flatness_fifo_cover \
		tests/formal/flatness_transaction_fifo.sby cover

rtl-clean:
	rm -rf obj_dir obj_multi
