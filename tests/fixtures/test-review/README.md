Calibration cases for `scripts/test-review.sh --calibrate`. Each directory is
one reviewed unit: `test.bats` (one test), `code.txt` (the code under test)
and `expect` (the check ids that must fire; empty for a clean case). The bad
cases are the failure shapes `docs/learnings/test-methodology.md` describes.
These files are data for Jev, not tests bats runs.
