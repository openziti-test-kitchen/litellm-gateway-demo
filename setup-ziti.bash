#!/usr/bin/env bash

# setup-ziti.bash - Idempotently create OpenZiti entities for the LiteLLM semantic routing demo
#
# Prerequisites:
#   - ziti CLI installed and logged in to your controller
#   - ZITI_IDENTITIES_DIR environment variable set (default: ./identities)
#
# Usage:
#   ./setup-ziti.bash [delete]

set -euo pipefail

IDENTITIES_DIR="${ZITI_IDENTITIES_DIR:=/identities}"
mkdir -p "$IDENTITIES_DIR"

# Docker Compose project name (defaults to current directory name)
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-litellm-gateway-demo}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

# Helper to check if entity exists using --csv output
entity_exists() {
    local entity_type="$1"
    local filter="$2"
    local name="$3"
    ziti edge list "$entity_type" "$filter" --csv 2>/dev/null | grep -q "$name"
}

# Helper to delete entity if it exists
delete_entity() {
    local entity_type="$1"
    local name="$2"
    local filter="name=\"$name\""
    
    if entity_exists "$entity_type" "$filter" "$name"; then
        log "Deleting $entity_type: $name"
        ziti edge delete "$entity_type" "$name"
    else
        log "$entity_type not found: $name"
    fi
}

# Handle delete subcommand
if [[ "${1:-}" == "delete" ]]; then
    log "Deleting all Ziti entities for project: $COMPOSE_PROJECT_NAME"

    # Delete Service Policies
    delete_entity "service-policies" "${COMPOSE_PROJECT_NAME}-ollama-dial-policy"
    delete_entity "service-policies" "${COMPOSE_PROJECT_NAME}-ollama-bind-policy"
    delete_entity "service-policies" "${COMPOSE_PROJECT_NAME}-litellm-dial-policy"
    delete_entity "service-policies" "${COMPOSE_PROJECT_NAME}-litellm-bind-policy"

    # Delete Services
    delete_entity "services" "${COMPOSE_PROJECT_NAME}-ollama-service"
    delete_entity "services" "${COMPOSE_PROJECT_NAME}-litellm-service"

    # Delete Configs
    delete_entity "configs" "${COMPOSE_PROJECT_NAME}-ollama-host-config"
    delete_entity "configs" "${COMPOSE_PROJECT_NAME}-ollama-intercept-config"
    delete_entity "configs" "${COMPOSE_PROJECT_NAME}-litellm-host-config"
    delete_entity "configs" "${COMPOSE_PROJECT_NAME}-litellm-intercept-config"

    # Delete Edge Routers
    delete_entity "edge-routers" "${COMPOSE_PROJECT_NAME}-ollama-router"
    delete_entity "edge-routers" "${COMPOSE_PROJECT_NAME}-litellm-router"

    log "Teardown complete!"
    exit 0
fi

#############################################################################
# Identities
#############################################################################

LITELLM_IDENTITY="${COMPOSE_PROJECT_NAME}-litellm-router"
LITELLM_JWT="$IDENTITIES_DIR/$LITELLM_IDENTITY.jwt"

if ! entity_exists "edge-routers" "name=\"$LITELLM_IDENTITY\"" "$LITELLM_IDENTITY"; then
    log "Creating router: $LITELLM_IDENTITY"
    ziti edge create edge-router "$LITELLM_IDENTITY" \
        --tunneler-enabled \
        --jwt-output-file "$LITELLM_JWT"
    log "Saved enrollment token to $LITELLM_JWT"
    chmod 0644 "$LITELLM_JWT"
    # Create router-specific env file for Docker Compose
    echo "ZITI_ENROLL_TOKEN=$(cat "$LITELLM_JWT")" > "$IDENTITIES_DIR/litellm-router.env"
    ziti edge update identity "$LITELLM_IDENTITY" \
        --role-attributes "${COMPOSE_PROJECT_NAME}-litellm-host,${COMPOSE_PROJECT_NAME}-ollama-client"
else
    log "Router exists: $LITELLM_IDENTITY"
fi

OLLAMA_IDENTITY="${COMPOSE_PROJECT_NAME}-ollama-router"
OLLAMA_JWT="$IDENTITIES_DIR/$OLLAMA_IDENTITY.jwt"

if ! entity_exists "edge-routers" "name=\"$OLLAMA_IDENTITY\"" "$OLLAMA_IDENTITY"; then
    log "Creating router: $OLLAMA_IDENTITY"
    ziti edge create edge-router "$OLLAMA_IDENTITY" \
        --tunneler-enabled \
        --jwt-output-file "$OLLAMA_JWT"
    log "Saved enrollment token to $OLLAMA_JWT"
    chmod 0644 "$OLLAMA_JWT"
    # Create router-specific env file for Docker Compose
    echo "ZITI_ENROLL_TOKEN=$(cat "$OLLAMA_JWT")" > "$IDENTITIES_DIR/ollama-router.env"
    ziti edge update identity "$OLLAMA_IDENTITY" \
        --role-attributes "${COMPOSE_PROJECT_NAME}-ollama-host"
else
    log "Router exists: $OLLAMA_IDENTITY"
fi

#############################################################################
# Service 1: User → LiteLLM (litellm-service)
#############################################################################

if ! entity_exists "configs" "name=\"${COMPOSE_PROJECT_NAME}-litellm-intercept-config\"" "${COMPOSE_PROJECT_NAME}-litellm-intercept-config"; then
    log "Creating config: ${COMPOSE_PROJECT_NAME}-litellm-intercept-config"
    ziti edge create config "${COMPOSE_PROJECT_NAME}-litellm-intercept-config" intercept.v1 \
        '{"protocols": ["tcp"], "addresses": ["litellm.ziti.internal"], "portRanges": [{"low": 4000, "high": 4000}]}'
else
    log "Config exists: ${COMPOSE_PROJECT_NAME}-litellm-intercept-config"
fi

if ! entity_exists "configs" "name=\"${COMPOSE_PROJECT_NAME}-litellm-host-config\"" "${COMPOSE_PROJECT_NAME}-litellm-host-config"; then
    log "Creating config: ${COMPOSE_PROJECT_NAME}-litellm-host-config"
    ziti edge create config "${COMPOSE_PROJECT_NAME}-litellm-host-config" host.v1 \
        '{"protocol": "tcp", "address": "127.0.0.1", "port": 4000}'
else
    log "Config exists: ${COMPOSE_PROJECT_NAME}-litellm-host-config"
fi

if ! entity_exists "services" "name=\"${COMPOSE_PROJECT_NAME}-litellm-service\"" "${COMPOSE_PROJECT_NAME}-litellm-service"; then
    log "Creating service: ${COMPOSE_PROJECT_NAME}-litellm-service"
    ziti edge create service "${COMPOSE_PROJECT_NAME}-litellm-service" \
        --configs "${COMPOSE_PROJECT_NAME}-litellm-intercept-config,${COMPOSE_PROJECT_NAME}-litellm-host-config"
else
    log "Service exists: ${COMPOSE_PROJECT_NAME}-litellm-service"
fi

if ! entity_exists "service-policies" "name=\"${COMPOSE_PROJECT_NAME}-litellm-bind-policy\"" "${COMPOSE_PROJECT_NAME}-litellm-bind-policy"; then
    log "Creating service-policy: ${COMPOSE_PROJECT_NAME}-litellm-bind-policy"
    ziti edge create service-policy "${COMPOSE_PROJECT_NAME}-litellm-bind-policy" Bind --semantic "AnyOf" \
        --service-roles "@${COMPOSE_PROJECT_NAME}-litellm-service" --identity-roles "#${COMPOSE_PROJECT_NAME}-litellm-host"
else
    log "Service-policy exists: ${COMPOSE_PROJECT_NAME}-litellm-bind-policy"
fi

if ! entity_exists "service-policies" "name=\"${COMPOSE_PROJECT_NAME}-litellm-dial-policy\"" "${COMPOSE_PROJECT_NAME}-litellm-dial-policy"; then
    log "Creating service-policy: ${COMPOSE_PROJECT_NAME}-litellm-dial-policy"
    ziti edge create service-policy "${COMPOSE_PROJECT_NAME}-litellm-dial-policy" Dial --semantic "AnyOf" \
        --service-roles "@${COMPOSE_PROJECT_NAME}-litellm-service" --identity-roles "#${COMPOSE_PROJECT_NAME}-llm-users"
else
    log "Service-policy exists: ${COMPOSE_PROJECT_NAME}-litellm-dial-policy"
fi

#############################################################################
# Service 2: LiteLLM → Ollama (ollama-service)
#############################################################################

if ! entity_exists "configs" "name=\"${COMPOSE_PROJECT_NAME}-ollama-intercept-config\"" "${COMPOSE_PROJECT_NAME}-ollama-intercept-config"; then
    log "Creating config: ${COMPOSE_PROJECT_NAME}-ollama-intercept-config"
    ziti edge create config "${COMPOSE_PROJECT_NAME}-ollama-intercept-config" intercept.v1 \
        '{"protocols": ["tcp"], "addresses": ["ollama.ziti.internal"], "portRanges": [{"low": 11434, "high": 11434}]}'
else
    log "Config exists: ${COMPOSE_PROJECT_NAME}-ollama-intercept-config"
fi

if ! entity_exists "configs" "name=\"${COMPOSE_PROJECT_NAME}-ollama-host-config\"" "${COMPOSE_PROJECT_NAME}-ollama-host-config"; then
    log "Creating config: ${COMPOSE_PROJECT_NAME}-ollama-host-config"
    ziti edge create config "${COMPOSE_PROJECT_NAME}-ollama-host-config" host.v1 \
        '{"protocol": "tcp", "address": "127.0.0.1", "port": 11434}'
else
    log "Config exists: ${COMPOSE_PROJECT_NAME}-ollama-host-config"
fi

if ! entity_exists "services" "name=\"${COMPOSE_PROJECT_NAME}-ollama-service\"" "${COMPOSE_PROJECT_NAME}-ollama-service"; then
    log "Creating service: ${COMPOSE_PROJECT_NAME}-ollama-service"
    ziti edge create service "${COMPOSE_PROJECT_NAME}-ollama-service" \
        --configs "${COMPOSE_PROJECT_NAME}-ollama-intercept-config,${COMPOSE_PROJECT_NAME}-ollama-host-config"
else
    log "Service exists: ${COMPOSE_PROJECT_NAME}-ollama-service"
fi

if ! entity_exists "service-policies" "name=\"${COMPOSE_PROJECT_NAME}-ollama-bind-policy\"" "${COMPOSE_PROJECT_NAME}-ollama-bind-policy"; then
    log "Creating service-policy: ${COMPOSE_PROJECT_NAME}-ollama-bind-policy"
    ziti edge create service-policy "${COMPOSE_PROJECT_NAME}-ollama-bind-policy" Bind --semantic "AnyOf" \
        --service-roles "@${COMPOSE_PROJECT_NAME}-ollama-service" --identity-roles "#${COMPOSE_PROJECT_NAME}-ollama-host"
else
    log "Service-policy exists: ${COMPOSE_PROJECT_NAME}-ollama-bind-policy"
fi

if ! entity_exists "service-policies" "name=\"${COMPOSE_PROJECT_NAME}-ollama-dial-policy\"" "${COMPOSE_PROJECT_NAME}-ollama-dial-policy"; then
    log "Creating service-policy: ${COMPOSE_PROJECT_NAME}-ollama-dial-policy"
    ziti edge create service-policy "${COMPOSE_PROJECT_NAME}-ollama-dial-policy" Dial --semantic "AnyOf" \
        --service-roles "@${COMPOSE_PROJECT_NAME}-ollama-service" --identity-roles "#${COMPOSE_PROJECT_NAME}-ollama-client"
else
    log "Service-policy exists: ${COMPOSE_PROJECT_NAME}-ollama-dial-policy"
fi

#############################################################################
# Summary
#############################################################################

log ""
log "Setup complete!"
log ""
log "Enrollment tokens saved to:"
log "  - $LITELLM_JWT"
log "  - $OLLAMA_JWT"
log ""
log "Next steps:"
log "  1. Copy enrollment tokens to your .env file:"
log "     LITELLM_ZITI_ENROLL_TOKEN=\$(cat $LITELLM_JWT)"
log "     OLLAMA_ZITI_ENROLL_TOKEN=\$(cat $OLLAMA_JWT)"
log ""
log "  2. Start the services:"
log "     docker compose up -d"
log ""
log "  3. Pull Ollama models:"
log "     docker compose exec ollama ollama pull nomic-embed-text:latest"
log "     docker compose exec ollama ollama pull llama3.2:3b"
