.PHONY: golden images model model-clean model-run rtl-clean rtl-e2e rtl-e2e-flat-model rtl-e2e-vlc-model rtl-e2e-bp-model rtl-e2e-bp-mpp-model rtl-e2e-bp-vlc-model rtl-e2e-bp-ich-model rtl-vlc-capture rtl-vlc-capture-bp-model rtl-vlc-replay rtl-vlc-replay-bp-model rtl-flatness-replay rtl-lint rtl-slang rtl-smoke

GOLDEN_SEED ?= 0x445343
GOLDEN_PATTERN ?= random
BLOCK_PRED ?= 1

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

rtl-lint:
	verilator --lint-only --timing -Wall -Wno-fatal \
		--top-module dsc_encoder -f tests/verilator/rtl.f

rtl-slang:
	slang --std 1800-2017 --top dsc_encoder -f tests/verilator/rtl.f

rtl-smoke:
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD \
		--top-module tb_dsc_encoder -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_encoder.sv
	./obj_dir/Vtb_dsc_encoder

rtl-e2e: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv
	./obj_dir/Vtb_dsc_e2e

# 用独立 C++ function model 替换行尾 flatness QP 调整，用于模块级 A/B。
rtl-e2e-flat-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_FLATNESS_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/flatness_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 用 C++ function model 替换首差异所在的 chroma ICH VLC 发射路径。
rtl-e2e-vlc-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_VLC_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/vlc_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 在完整顶层只替换整个 BP vector/predict 模块。
rtl-e2e-bp-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_BPVECTOR_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/bpvector_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 在 BP 替身基线上完整替换三个 MPP 实例，验证 midpoint 子模块边界。
rtl-e2e-bp-mpp-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_BPVECTOR_MODEL_SUBSTITUTE -DDSC_MPP_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/bpvector_function_model.cpp \
		tests/verilator/model/mpp_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 在 BP 替身基线上完整替换三个 VLC 实例，区分 syntax 与上游决策差异。
rtl-e2e-bp-vlc-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_BPVECTOR_MODEL_SUBSTITUTE -DDSC_VLC_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/bpvector_function_model.cpp \
		tests/verilator/model/vlc_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 在 BP 替身基线上完整替换 ICH（history、candidate、decision 全部在边界内）。
rtl-e2e-bp-ich-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_BPVECTOR_MODEL_SUBSTITUTE -DDSC_ICH_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/bpvector_function_model.cpp \
		tests/verilator/model/ich_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 从真实顶层 RTL 捕获 dsce_vlc 公开输入，不包含 golden 输出。
rtl-vlc-capture: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_VLC_CAPTURE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv
	./obj_dir/Vtb_dsc_e2e

# 从 BP 替换后的可信上游捕获 512 个完整 VLC 边界事务。
rtl-vlc-capture-bp-model: golden
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD -DDSC_VLC_CAPTURE -DDSC_BPVECTOR_MODEL_SUBSTITUTE \
		--top-module tb_dsc_e2e -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_e2e.sv tests/verilator/model/bpvector_function_model.cpp
	./obj_dir/Vtb_dsc_e2e

# 用同一顶层输入 trace 对比完整 RTL VLC 与完整 function model。
rtl-vlc-replay: rtl-vlc-capture
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-BLKSEQ -Wno-TIMESCALEMOD \
		--top-module tb_dsc_vlc_replay \
		verilog_dsc/dsce_defs_pkg.sv verilog_dsc/dsce_vlc.sv \
		verilog_dsc/dsce_vlc_function_model.sv tests/verilator/tb_dsc_vlc_replay.sv \
		tests/verilator/model/vlc_function_model.cpp
	./obj_dir/Vtb_dsc_vlc_replay

rtl-vlc-replay-bp-model: rtl-vlc-capture-bp-model
	verilator --binary --timing --assert -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-BLKSEQ -Wno-TIMESCALEMOD \
		--top-module tb_dsc_vlc_replay \
		verilog_dsc/dsce_defs_pkg.sv verilog_dsc/dsce_vlc.sv \
		verilog_dsc/dsce_vlc_function_model.sv tests/verilator/tb_dsc_vlc_replay.sv \
		tests/verilator/model/vlc_function_model.cpp
	./obj_dir/Vtb_dsc_vlc_replay

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

rtl-clean:
	rm -rf obj_dir
