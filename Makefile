.PHONY: images model model-clean model-run rtl-clean rtl-lint rtl-smoke

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

rtl-smoke:
	verilator --binary --timing -Wall -Wno-fatal \
		-Wno-WIDTH -Wno-UNUSED -Wno-IMPORTSTAR -Wno-PINCONNECTEMPTY \
		-Wno-BLKSEQ -Wno-DECLFILENAME -Wno-GENUNNAMED -Wno-MULTIDRIVEN \
		-Wno-TIMESCALEMOD \
		--top-module tb_dsc_encoder -f tests/verilator/rtl.f \
		tests/verilator/tb_dsc_encoder.sv
	./obj_dir/Vtb_dsc_encoder

rtl-clean:
	rm -rf obj_dir
