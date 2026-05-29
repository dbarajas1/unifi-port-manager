ARG BUILD_FROM
FROM $BUILD_FROM

# Install Node.js (LTS)
RUN apk add --no-cache nodejs

WORKDIR /
COPY run.sh /run.sh
COPY port-api.js /port-api.js

RUN chmod a+x /run.sh

CMD ["/run.sh"]
