Calibration cases for `scripts/test-review.sh --calibrate`. Each directory is
one reviewed unit: `test.bats`, `code.txt` (the code under test) and `expect`
(the check ids that must fire; empty for a clean case). With a `level` file
holding `function`, the whole `test.bats` is reviewed as one function's
suite (near misses, real tools, stubs, [PASS] guards), and `diff.txt` is the
change to that function the suite must reach; otherwise each test is
reviewed alone. The bad cases are the failure shapes
`docs/learnings/test-methodology.md` describes, and each suite-level check
has a clean counterpart. A case passes only when every sample clears every
check's line by the checks file's `band`, on the right side. These files are
data for Jev, not tests bats runs.
