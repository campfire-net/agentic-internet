.PHONY: docs docs-check

# Regenerate all sentinel-marked sections from declarations.
# Direct alternative: python3 bin/gen-docs
docs:
	python3 bin/gen-docs

# CI target: fail if generated sections are stale.
# Direct alternative: python3 bin/gen-docs --check
docs-check:
	python3 bin/gen-docs --check
