export PACKAGE_MANAGER=apk
include ../../minimizer.makefile

test:
	$(MAKE) minimize docker-image
	$(MAKE) docker-run | grep 'hello world'

.PHONY: test
