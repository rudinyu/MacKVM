# Development workflow

## During feature development

After every code change, run:

```sh
./.codex/ci.sh
```

This local CI command builds the app and runs all tests. Do **not** run code
review after each edit or each successful CI run.

## After each plan step

A step is complete when that step's implementation, tests, documentation, and
acceptance criteria are all finished. Only then run:

```sh
./.codex/step-review.sh
```

This runs local CI and then one Codex review over the complete step diff. If the
plan has 6 steps, run this 6 times: once after each completed step. Claude
code-reviewer is not used at individual step boundaries.

If review feedback requires code changes:

1. Apply the full batch of valid review fixes.
2. Run `./.codex/ci.sh` after each code change as usual.
3. Re-run `./.codex/step-review.sh` once after all review fixes are complete.

Do not continue past the completed step until it passes CI and has no valid Codex
Must Fix findings. Handle valid low-risk Should Fix findings before committing,
or document why they were skipped.

## After all plan steps

After every step in the complete plan is finished, run:

```sh
./.codex/final-review.sh
```

This performs the final local CI and Claude code-reviewer pass over the complete
plan diff. Fix valid findings as one batch, run local CI after each change, run
a Codex step review for the fix batch, and then re-run the final Claude review
once.
