FROM alpine:latest

# Install bash and GNU coreutils (for reliable du and stat commands)
RUN apk add --no-cache bash coreutils

WORKDIR /app
COPY pump.sh /app/pump.sh
RUN chmod +x /app/pump.sh

CMD ["/app/pump.sh"]