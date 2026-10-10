.PHONY: test benchmark syntax-benchmark format-check

test:
	sh tests/nvim/run.sh

benchmark:
	sh tests/nvim/run.sh --benchmark

syntax-benchmark:
	python3 tests/nvim/syntax_benchmark.py

format-check:
	stylua --check --verify lua tests
