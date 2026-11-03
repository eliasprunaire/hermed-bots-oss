# hv-hermes:spike, the throwaway Hermes of the spike S1 to S7 (HD-01)
# Base: the official image. Q11 decided `latest`; the exact version observed goes in each report
# Build: docker build -t hv-hermes:spike .cursor/skills/verify-hermed-bots/orb
ARG HERMES_IMAGE=nousresearch/hermes-agent:latest
FROM ${HERMES_IMAGE}

COPY fake-llm.py hv-start.sh /opt/hv/
RUN chmod 0755 /opt/hv/fake-llm.py /opt/hv/hv-start.sh

# API server on, inside the container only. The key (API_SERVER_KEY) is set at start from
# HV_TEST_API_KEY. The bind is 0.0.0.0 in the container so the published port reaches it; the
# publication is 127.0.0.1 on the Mac, set by hv-hermes-env.sh
ENV API_SERVER_ENABLED=true \
    API_SERVER_HOST=0.0.0.0 \
    GATEWAY_MULTIPLEX_PROFILES=true

# The base image runs CMD as the `hermes` user after its own init
CMD ["/opt/hv/hv-start.sh"]
