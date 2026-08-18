# Hierarchical Model Substitution Debugging

## Goal

Localize RTL failures by replacing selected RTL modules with trusted
reference models and observing whether the end-to-end failure disappears.

Use this workflow before deep internal probing when the failing design
contains multiple hierarchical modules.

## Preconditions

A replacement model must have a defined boundary contract with the RTL module:

- equivalent input/output transaction semantics
- defined reset behavior
- defined handshake semantics
- known timing policy

Do not require equivalent internal state or implementation structure.

## Workflow

1. Reproduce the end-to-end failure with the original RTL hierarchy.

2. Start at the highest useful module boundary.

3. Replace one candidate child RTL module with its trusted model while
   keeping the rest of the design unchanged.

4. Re-run exactly the same failing test.

5. Interpret the result:
   - FAIL → this replacement did not remove the observed failure.
   - PASS → the replaced module or its boundary interaction becomes a
     primary suspect.
   - DIFFERENT FAILURE → investigate interface / timing compatibility
     before drawing conclusions.

6. Restore the module before testing another candidate unless performing
   an explicitly controlled multi-module experiment.

7. Once a suspect module is identified:
   - descend into its child hierarchy and repeat A/B substitution, or
   - invoke RTL debugging using LSP, waveform, assertions, and structural
     queries if the module is already small enough.

## Alignment Discipline

Compare replacement models at stable module boundaries.

Align in this order:

`transaction semantics → event order → timing → internal state`

Do not require cycle-by-cycle internal probe equivalence unless explicitly
necessary.

## Rules

- Change only one experimental variable per A/B trial.
- Never treat PASS after replacement as proof that the replaced RTL alone
  is faulty.
- Check wrapper, interface, reset, latency, and handshake differences.
- Record every substitution and result.
- Stop descending when the suspect module is small enough for direct RTL
  debugging.