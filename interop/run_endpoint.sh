#!/bin/bash
# Endpoint entrypoint for the QUIC Interop Runner.
set -e

# The runner's simulator gates traffic on this file existing.
if [ -f /setup.sh ]; then
    /setup.sh
fi

echo "Starting swift-quic endpoint: ROLE=$ROLE TESTCASE=$TESTCASE"
exec /usr/bin/quic-interop
