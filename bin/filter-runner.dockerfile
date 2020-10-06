FROM alpine:3.12

WORKDIR /filter-runner
ADD filter-tarball.sh ./
RUN apk add --no-cache bash tar

ENTRYPOINT [ \
  "/bin/bash", "/filter-runner/filter-tarball.sh", \
  "-i", "/filter-runner/volume/exported-full-image.tar", \
  "-v", "/filter-runner/volume/.dockerinclude", \
  "-o", "/filter-runner/volume/content.tar.gz" \
]
