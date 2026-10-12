# Aliases for the scripts; see README "Tests".
.PHONY: test coverage
test:
	scripts/test.sh $(ARGS)

coverage:
	scripts/test.sh --coverage $(ARGS)
