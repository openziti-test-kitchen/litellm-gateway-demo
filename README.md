
# LiteLLM Semantic Routing Gateway Demo

This demonstrates how to route sensitive AI prompts to a private model while sending everything else to a public provider. It uses semantic similarity to decide where each prompt should go—keeping private data private without blocking general questions.

## What This Demonstrates

- **Semantic routing**: Incoming prompts are compared against a set of predefined utterances using an embeddings model. When similarity is high, the prompt routes to a private model; otherwise, it falls back to a public provider.
- **Private model hosting**: Ollama serves private models over an OpenZiti network, keeping them inaccessible from the public internet.
- **Zero-trust connectivity**: OpenZiti provides secure, identity-based access for the entire pipeline—users connect to LiteLLM, and LiteLLM connects to Ollama—without exposing any service publicly.

## Software Stack

| Component | Purpose |
|-----------|---------|
| [**LiteLLM**](https://docs.litellm.ai/docs/proxy/auto_routing) | Semantic routing LLM gateway that evaluates prompts and routes to appropriate backends |
| [**Ollama**](https://ollama.com/) | Hosts private models, including a fast embeddings model for semantic similarity evaluation |
| [**OpenZiti**](https://netfoundry.io/docs/openziti/learn/introduction) | Zero-trust networking overlay that securely connects LiteLLM to Ollama |

## Prerequisites

- An operational OpenZiti network
- Access to a Ziti admin identity JSON file (e.g. `ziti-admin.json`)
- Docker and Docker Compose (or equivalent container runtime)
- Access to a public LLM provider API (e.g., OpenRouter, OpenAI, Anthropic) for fallback routing

## Project Files

| File | Purpose |
|------|---------|
| `compose.yaml` | Docker Compose with LiteLLM, Ollama, and Ziti router sidecars |
| `litellm_config.yaml` | LiteLLM semantic routing configuration with utterances |
| `setup-ziti.bash` | Idempotent script to create all Ziti entities |
| `.env.example` | Template for environment variables |

## Running It Yourself

### 1. Create Ziti Entities

Run the setup script using the `openziti/ziti-cli` container image. You'll need your Ziti admin identity JSON file.

```bash
# Run setup script in container
# Replace ./ziti-admin.json with the path to your admin identity
docker run --rm \
  -v "${PWD}/ziti-admin.json":/ziti-admin.json:ro \
  -v "${PWD}/setup-ziti.bash":/setup-ziti.bash:ro \
  -v "${PWD}/identities":/identities \
  -w / \
  -u 0 \
  --entrypoint /usr/bin/env \
  openziti/ziti-cli \
  bash -c "ziti edge login --file /ziti-admin.json --yes && /setup-ziti.bash"
```

This creates:

- **Edge Routers**: `litellm-router` and `ollama-router` with built-in tunnelers enabled and assigned role attributes
- **Configs**: intercept.v1 and host.v1 for both services
- **Services**: `litellm-service` and `ollama-service`
- **Service Policies**: Bind and Dial policies for each service

Enrollment tokens are saved to router-specific env files in `./identities/` which are automatically loaded by Docker Compose.

### 2. Configure Environment

```bash
cp .env.example .env
```

Edit `.env` and add:

- **Public LLM API key** (at least one: OpenRouter, OpenAI, Anthropic, or Gemini)

Then edit `litellm_config.yaml` to set the public model matching your API key:

```yaml
# Public model (fallback) - for general queries
- model_name: "public-model"
  litellm_params:
    model: "gemini/gemini-2.0-flash"  # Change to match your API key provider
```

See [LiteLLM Providers](https://docs.litellm.ai/docs/providers) for model name formats.

### 3. Customize Utterances

Edit `litellm_config.yaml` to define what prompts should route to your private model:

```yaml
model_info:
  utterances:
    - "What are our internal policies on"
    - "Summarize the confidential report about"
    - "Explain our proprietary process for"
    # Add utterances specific to your use case
```

### 4. Start the Services

```bash
docker compose up -d
```

**With NVIDIA GPU support** (optional):

Add to `.env` file:

```bash
COMPOSE_FILE=compose.yaml:compose.gpu.yaml
```

> Requires NVIDIA Container Toolkit. See [NVIDIA Container Toolkit Installation Guide](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html).

### 5. Pull Ollama Models

```bash
docker compose exec ollama ollama pull nomic-embed-text   # Embeddings model
docker compose exec ollama ollama pull llama3.2:3b        # Private LLM (or your choice)
```

### 6. Grant User Access

Create identities for users/agents that should access LiteLLM:

```bash
ziti edge create identity "my-user" --role-attributes "llm-users"
```

### 7. Add Ziti Identity to Tunnel

Add the `my-user` identity to the Ziti tunneler on the device where you will access the litellm service.

### 8. Test Connectivity

```bash
curl -s http://litellm.ziti.internal:4000/v1/models | jq
```

### 9. Use the Auto Router

Once auto-routing is configured, requests should set `model` to the router alias (`auto-router` in this demo). LiteLLM will compare the prompt against the router configuration, dispatching to `private-model` when the utterances match and falling back to `public-model` otherwise:

```bash
curl http://litellm.ziti.internal:4000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "auto-router",
    "messages": [
      { "role": "user", "content": "Summarize the confidential report about our process." }
    ]
  }'
```

## How It Works

```text
┌─────────────────────────────────────┐
│  ┌─────────────────────────────┐    │
│  │     Ziti Tunnel / SDK       │    │
│  └─────────────────────────────┘    │
│         │                           │
│         ▼                           │
│  ┌─────────────────────────────┐    │
│  │      User / Agent Client    │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
          │
          │ OpenZiti overlay (litellm-service)
          ▼
┌─────────────────────────────────────┐     ┌─────────────┐
│  ┌─────────────────────────────┐    │     │   Public    │
│  │     Ziti Router Sidecar     │    │────▶│   LLM API   │
│  └─────────────────────────────┘    │     └─────────────┘
│         │                           │            ▲
│         ▼                           │            │
│  ┌─────────────────────────────┐    │      low similarity
│  │       LiteLLM Gateway       │    │            │
│  │  (semantic similarity check)│────│────────────┘
│  └─────────────────────────────┘    │
│         │ high similarity           │
│         ▼                           │
│  ┌─────────────────────────────┐    │
│  │     Ziti Router Sidecar     │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
          │
          │ OpenZiti overlay (ollama-service)
          ▼
┌─────────────────────────────────────┐
│  ┌─────────────────────────────┐    │
│  │     Ziti Router Sidecar     │    │
│  └─────────────────────────────┘    │
│         │                           │
│         ▼                           │
│  ┌─────────────────────────────┐    │
│  │          Ollama             │    │
│  │   (private models hosted)   │    │
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

1. A user/agent with a Ziti identity connects to the LiteLLM gateway via `litellm-service`
2. LiteLLM computes embeddings for the prompt and compares against configured utterances
3. If similarity exceeds the threshold, the prompt routes through `ollama-service` to the private Ollama instance
4. If similarity is low, the prompt routes to the configured public LLM provider

**Security note**: No API keys or authentication tokens are required at the application layer. Access to LiteLLM and Ollama are controlled entirely by authenticating Ziti identities authorized by Ziti service policies.

## License

See [LICENSE](LICENSE) for details.
