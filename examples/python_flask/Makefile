test: minimize .docker-image
	./verify.sh -i $(shell cat .docker-image)

.docker-image: .dockerinclude
	../../bin/minimize.sh

minimize: .
	../../bin/strace-docker.sh -p apt -d "--publish 8000:5000" -t ./verify.sh

.PHONY: minimize test
