---
name: rtl-debugging
description: >
   Debug SystemVerilog RTL failures using structured evidence.

   Prefer semantic navigation, simulation evidence, waveform inspection, and assertions over ad-hoc instrumentation.
---
# RTL Debugging Skill

## Goal

Debug SystemVerilog RTL failures using structured evidence.

Prefer semantic navigation, simulation evidence, waveform inspection, and assertions over ad-hoc instrumentation.

## Tools

Use available open-source tools:

* **LSP**: hover, go-to-definition, find-references, document symbols, diagnostics.
* **slang / pyslang**: SystemVerilog semantic and structural queries.
* **Verilator**: compile, simulate, assertions, waveform generation.
* **FST/VCD**: inspect runtime signal values.

## Workflow

When a test fails:

1. **Reproduce**

   * Run the smallest failing test.
   * Record diagnostics and failing outputs.
   * Do not modify RTL yet.

2. **Navigate semantically**

   * For suspicious signals, states, modules, or parameters, prefer LSP before text search.
   * Use:

     * `definition` to locate declarations and assignments.
     * `references` to find semantic uses.
     * `hover` to inspect types, widths, symbols, and signatures.
     * `diagnostics` to inspect compiler/LSP errors.
   * Use `grep/rg` only when LSP cannot answer the question or broad textual search is actually required.

3. **Locate the first behavioral divergence**

   * Find the earliest mismatching cycle/time and output signal.
   * Inspect only a small waveform window around the mismatch.
   * Trace relevant inputs, registers, FSM states, handshake signals, clocks, and resets.

4. **Trace the cause**

   * Combine runtime waveform evidence with LSP/slang navigation.
   * Follow the suspicious signal back to its driver, state update, or dependency.
   * Form a concrete root-cause hypothesis before editing RTL.

5. **Test the hypothesis**

   * Prefer targeted assertions or focused test cases.
   * Re-run the failing case and verify the suspected condition.
   * Use `$display` only if LSP, waveform, diagnostics, and assertions cannot expose the required information.

6. **Patch and verify**

   * Make the smallest root-cause fix.
   * Re-run the failing test and related regressions.
   * Confirm no new diagnostics or assertion failures.

## Debugging Discipline

Use evidence in this order:

`diagnostics → LSP navigation → first mismatch → waveform → structural query → assertion → $display`

Rules:

* Do not start debugging by inserting `$display`.
* Do not replace semantic navigation with `grep` by default.
* Do not patch RTL before identifying a concrete failure mechanism.
* Do not dump full waveforms into the model context.
* Prefer `definition/references` over manually scanning large files.
* Prefer structural and runtime evidence that can be reproduced.
* Keep DUT instrumentation temporary and minimal.

## Debug Report

Record:

* failing test
* first mismatch: signal + cycle/time
* relevant LSP navigation results
* relevant waveform evidence
* root cause
* RTL patch
* regression result

## Probe Alignment Discipline

Do not assume internal signals or cycles are directly comparable across models.

Align observations in this order:

1. **Transaction / semantic event**
   - accepted input
   - produced output
   - request / response
   - state transition
   - commit / completion

2. **Event index**
   - compare the N-th accepted transaction with the N-th accepted transaction
   - compare the N-th output with the N-th output

3. **Timing**
   - only after semantic events match, determine cycle / latency offset

4. **Internal probes**
   - compare internal state only when both models expose semantically equivalent state

Do not spend multiple iterations forcing non-equivalent internal probes to match.

If probe equivalence is unclear:
- move outward to a stable module boundary
- compare transactions instead of raw signals
- record the uncertainty explicitly