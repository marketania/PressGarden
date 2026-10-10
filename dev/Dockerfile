# Development tools only; this image is not a production deployment.
FROM debian:trixie-slim@sha256:a29215f6a35e51e22adffa17f89e9d2ef06214e64a2bad10d765c46aea49f11f

# Debian security updates stay available rather than freeze vulnerable packages.
COPY setup.sh /usr/local/share/press-dev-setup.sh
RUN bash /usr/local/share/press-dev-setup.sh

# The host downloads through its approved TLS/proxy setup. The artifact is
# checked again inside the build; no proxy credentials or custom trust is saved.
RUN --mount=type=bind,from=wp_cli,source=/wp-cli.phar,target=/tmp/wp-cli.phar,readonly \
    echo 'ce34ddd838f7351d6759068d09793f26755463b4a4610a5a5c0a97b68220d85c  /tmp/wp-cli.phar' | sha256sum -c - \
 && install -m 755 /tmp/wp-cli.phar /usr/local/bin/wp

ENV HOME=/tmp/press-dev-home PYTHONDONTWRITEBYTECODE=1 LANG=C.UTF-8
WORKDIR /work
USER 1000:1000
CMD ["bash"]
