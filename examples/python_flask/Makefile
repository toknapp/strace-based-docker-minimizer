export PACKAGE_MANAGER := apt
export DOCKER_RUN_OPTS := --publish 8000:5000
export TRIGGER_CMD := ./verify.sh
include ../../minimizer.makefile

test:
	$(MAKE) minimize docker-image
	./verify.sh -i $(DOCKER_IMAGE)

clean: minimizer-clean

.PHONY: test clean
