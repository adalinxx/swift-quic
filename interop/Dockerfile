# QUIC Interop Runner endpoint image for swift-quic.
# https://github.com/quic-interop/quic-interop-runner
FROM swift:6.3 AS build
WORKDIR /src
COPY Package.swift Package.resolved ./
COPY Sources ./Sources
COPY Tests ./Tests
RUN SWIFT_CERTIFICATES_ALLOW_SWIFT_CRYPTO_BETA=1 swift build -c release --product quic-interop

FROM swift:6.3-slim
COPY --from=build /src/.build/release/quic-interop /usr/bin/quic-interop
COPY interop/run_endpoint.sh /run_endpoint.sh
RUN chmod +x /run_endpoint.sh
ENTRYPOINT ["/run_endpoint.sh"]
