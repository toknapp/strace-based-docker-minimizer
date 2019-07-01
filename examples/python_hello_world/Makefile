export PACKAGE_MANAGER=apk
include ../../minimizer.makefile

test:
	$(MAKE) docker-run | grep 'hello world'

.PHONY: test
