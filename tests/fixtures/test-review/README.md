Calibration cases for `scripts/test-review.sh --calibrate`. Each directory is
one reviewed unit: `test.bats`, `code.txt` (the code under test) and `expect`
(the check ids that must fire; empty for a clean case). With a `level` file
holding `function`, the whole `test.bats` is reviewed as one function's
suite (near misses, real tools, stubs, [PASS] guards); otherwise each test
is reviewed alone. The bad cases are the failure shapes
`docs/learnings/test-methodology.md` describes, and each suite-level check
has a clean counterpart. These files are data for Jev, not tests bats runs.
