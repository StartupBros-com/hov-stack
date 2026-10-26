export PYTHONPATH := src

.PHONY: check
check:
	python3 -m unittest discover -s tests -q && python3 scripts/check.py
