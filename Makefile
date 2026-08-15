.PHONY: golden images model model-clean model-run rtl-clean rtl-e2e rtl-e2e-flat-model rtl-lint rtl-slang rtl-smoke

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

rtl-clean:
	rm -rf obj_dir
