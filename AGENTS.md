# Repository Guidelines

## Project Structure & Module Organization

`verilog_dsc/` contains the SystemVerilog DSC encoder RTL. The top level is `dsc_encoder.sv`; reusable blocks use the `dsce_*.sv` prefix, and shared declarations live in `dsce_defs_pkg.sv` and `dsce_regdefs_pkg.sv`. `model/` contains the C reference model: Linux sources are in `model/src/`, configurations in `model/config/`, original documentation in `model/docs/`, and Windows artifacts in `model/windows/`. `dsc_spec/` and `DSC v1.2b.pdf` are reference documents, not generated artifacts. Keep temporary simulations, waveforms, logs, and converted images outside the repository, preferably under `~/Work/dsc/`.

## Build, Test, and Development Commands

- `make model` builds the Linux reference executable as `model/src/dsc` with GCC.
- `make model-clean` removes reference-model objects and the executable.
- `make model-run` runs the model from `model/config/` with `test.cfg`; ensure the input paths named by `test_list.txt` exist.
- `git status --short` checks that model outputs such as `log.txt`, `*.dsc`, and `*.out.dpx` are not accidentally staged.

No repository-wide RTL build or simulator harness is currently provided. When adding one, document the exact compiler, top module, file order, and invocation here.

## Coding Style & Naming Conventions

Follow the surrounding RTL style: four-space indentation, one declaration per line, aligned port lists, `logic` types, and explicit widths. Preserve the established `dsce_` module/file prefix, `pUPPER_SNAKE_CASE` parameters, and lower-snake-case signals. Put shared types and constants in the appropriate package. For C, retain the Makefile's GNU99 and `-Wall` compatibility. Write new explanatory code comments in Chinese; keep identifiers and protocol names in English.

## Testing Guidelines

There is no automated test suite or stated coverage threshold. Validate C-model changes by rebuilding cleanly and running a representative `.cfg`. Validate RTL changes with compilation plus focused simulation, comparing encoded data or PPS fields against the reference model where applicable. Name new testbenches `tb_<module>.sv` and keep test-only files in a dedicated `tests/` directory.

## Commit & Pull Request Guidelines

History currently contains only an `init` commit, so no mature convention exists. Use concise imperative subjects, optionally scoped, for example `rtl: fix slice FIFO backpressure`. Keep generated outputs out of commits. Pull requests should describe the affected path, behavioral impact, configuration used for verification, and commands/results. Link relevant issues; attach waveforms or logs when timing or protocol behavior changes.
