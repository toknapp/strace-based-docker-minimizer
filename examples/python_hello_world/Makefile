test:
	../../bin/strace-docker.sh -p apk
	../../bin/minimize.sh
	cat .docker-image | xargs docker run --rm | grep -cq 'hello world'

.PHONY: test
