.PHONY: test golden images model model-clean model-run model-4k model-regression \
	model-compile-commands rtl-clean rtl-regression rtl-top rtl-flatness-replay \
	rtl-ich-decision-replay rtl-formal rtl-lint rtl-slang rtl-smoke

GOLDEN_SEED ?= 0x445343
GOLDEN_PATTERN ?= random
BLOCK_PRED ?= 1
REGRESSION_PARALLEL ?= 2
REGRESSION_PROFILE ?= quick
OFFICIAL_ARCHIVE ?= $(HOME)/Work/dsc/Display\ Stream\ Compression\ \(DSC\)\ Test\ Results-selected.zip
RTL_TB ?= tb_dsc_e2e
RTL_TB_FILE ?= tests/verilator/$(RTL_TB).sv
RTL_MDIR = $(if $(filter 1,$(RTL_COVERAGE)),$(COV_DIR)/obj,obj_dir)
RTL_RUN_ARGS ?=
RTL_TRACE ?= 0
RTL_COVERAGE ?= 0
COV_DIR ?= /tmp/dsc_cov
FORMAL_DIR ?= /tmp/dsc_formal
FORMAL_SUITE ?= flatness_transaction_fifo
FORMAL_TASK ?= prove
ICH_REPLAY_VECTOR ?= tests/verilator/vectors/ich_decision_vesa_boats_tx0_307.hex
ICH_REPLAY_COUNT ?= 308
ICH_REPLAY_MDIR ?= /tmp/dsc_ich_replay_obj
VERILATOR_WARNINGS := -Wall -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
	-Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY -Wno-BLKSEQ -Wno-DECLFILENAME \
	-Wno-GENUNNAMED -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD
VERILATOR_COMMON := --binary --timing --assert $(VERILATOR_WARNINGS)

ifeq ($(RTL_TRACE),1)
RTL_TOP_FLAGS += -DDSC_VCD_DUMP --trace --trace-depth 5
endif
ifeq ($(RTL_COVERAGE),1)
RTL_TOP_FLAGS += --coverage-line --coverage-toggle --coverage-underscore
RTL_COVERAGE_ARGS := +verilator+coverage+file+$(COV_DIR)/coverage.dat
endif

test: rtl-lint rtl-smoke rtl-regression model-regression

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
	python3 tools/run_dsc_regression.py --profile $(REGRESSION_PROFILE) --parallel $(REGRESSION_PARALLEL)

rtl-regression:
	python3 tools/run_rtl_regression.py --profile $(REGRESSION_PROFILE) \
		--official-archive $(OFFICIAL_ARCHIVE)

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
	mkdir -p $(RTL_MDIR)
	verilator $(VERILATOR_COMMON) $(RTL_TOP_FLAGS) \
		--top-module $(RTL_TB) -f tests/verilator/rtl.f \
		$(RTL_TB_FILE) --Mdir $(RTL_MDIR)
	$(RTL_MDIR)/V$(RTL_TB) $(RTL_RUN_ARGS) $(RTL_COVERAGE_ARGS)
ifeq ($(RTL_TRACE),1)
	@echo "VCD 波形已生成: tests/verilator/generated/rtl_e2e_trace.vcd"
endif
ifeq ($(RTL_COVERAGE),1)
	verilator_coverage $(COV_DIR)/coverage.dat --annotate $(COV_DIR)/annotate
	@echo "覆盖率产物: $(COV_DIR)/"
	@echo "看具体未覆盖行: grep '%000000' $(COV_DIR)/annotate/dsce_*.sv"
endif

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

# 从模块输入边界回放冻结事务；可用 ICH_REPLAY_VECTOR/COUNT 切换窗口。
rtl-ich-decision-replay:
	verilator $(VERILATOR_COMMON) \
		--top-module tb_dsce_ich_decision_replay \
		verilog_dsc/dsce_defs_pkg.sv verilog_dsc/dsce_ich_decision.sv \
		tests/verilator/tb_dsce_ich_decision_replay.sv --Mdir $(ICH_REPLAY_MDIR)
	$(ICH_REPLAY_MDIR)/Vtb_dsce_ich_decision_replay \
		+vector=$(ICH_REPLAY_VECTOR) +vector_count=$(ICH_REPLAY_COUNT)

# FORMAL_TASK=prove 证明安全契约；FORMAL_TASK=cover 生成边界反例轨迹。
rtl-formal:
	sby -f -d $(FORMAL_DIR)/$(FORMAL_SUITE)_$(FORMAL_TASK) \
		tests/formal/$(FORMAL_SUITE).sby $(FORMAL_TASK)

rtl-clean:
	rm -rf obj_dir obj_multi
