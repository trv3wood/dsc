.PHONY: model model-clean model-run

model:
	$(MAKE) -C model/src

model-clean:
	$(MAKE) -C model/src clean

model-run: model
	cd model/config && ../src/dsc -F test.cfg
