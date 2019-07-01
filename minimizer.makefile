export DOCKER ?= docker
export DOCKER_RUN_OPTS ?=
ROOT ?= $(realpath $(dir $(abspath $(lastword $(MAKEFILE_LIST)))))
export SCRIPTS_DIR ?= $(ROOT)/bin
DOCKER_INCLUDE ?= .dockerinclude
DOCKER_IMAGE ?= $(shell pwd | xargs basename)

minimize: .docker-image.flag
	$(SCRIPTS_DIR)/strace-docker.sh -f $(shell cat $<) \
		| $(SCRIPTS_DIR)/accessed-files.sh > $(DOCKER_INCLUDE)

docker-image: .docker-image.minimized.flag
	$(DOCKER) tag $(shell cat $<) $(DOCKER_IMAGE)

docker-run: .docker-image.minimized.flag
	$(DOCKER) run --rm $(DOCKER_RUN_OPTS) $(shell cat $<)

.docker-image.flag: Dockerfile
	$(DOCKER) build --iidfile=$@ .

.docker-image.minimized.flag: $(DOCKER_INCLUDE) .docker-image.flag
	$(SCRIPTS_DIR)/minimize.sh -f $(shell cat .docker-image.flag) \
		-v $(DOCKER_INCLUDE) > $@

minimizer-clean:
	rm -f .docker-image.flag .docker-image.minimized.flag

.PHONY: minimize docker-run docker-image minimizer-clean
