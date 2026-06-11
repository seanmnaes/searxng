# SearXNG Pipeline

Automated deployment of [SearXNG](https://github.com/searxng/searxng) on Linode (Akamai) using Terraform and GitHub Actions, with Cloudflare DNS, proxy, and Origin CA TLS.

## Architecture

- **Compute**: Linode Nanode 1GB running Alpine Linux (latest)
- **Application**: SearXNG Docker container (`docker.io/searxng/searxng:latest`) with a Valkey sidecar for the rate limiter
- **TLS**: Cloudflare Origin CA certificate (ECDSA P-256) with nginx reverse proxy, TLS 1.3 only
- **DNS/Proxy**: Cloudflare proxied `AAAA` record (IPv6); the origin firewall only admits Cloudflare's IPv6 ranges
- **SSL mode**: Full (Strict), enforced in Terraform (`cloudflare_zone_setting`)
- **Abuse protection**: SearXNG public-instance limiter backed by Valkey; nginx recovers the real client IP from Cloudflare
- **State**: Terraform Cloud
- **CI/CD**: GitHub Actions on push to `main` + daily redeploy at 04:00 PDT, with a post-deploy health check
- **Secret Rotation**: Automated every 28 days via GitHub Actions

## Project Structure

```
├── .github/workflows/
│   ├── deploy.yml          # GitHub Actions pipeline
│   └── rotate-secrets.yml  # Secret rotation every 28 days
└── terraform/
    ├── main.tf             # Linode instance, StackScript, Cloudflare DNS
    ├── variables.tf        # Variable definitions
    └── outputs.tf          # IP and URL outputs
```

## Prerequisites

### Terraform Cloud

1. Create an organization and workspace
2. Set workspace execution mode to **Local**

### Cloudflare

SSL/TLS mode is enforced as **Full (Strict)** by Terraform (`cloudflare_zone_setting`), so no manual dashboard step is required. The `CF_API_TOKEN` must carry the permissions listed under [GitHub Secrets](#github-secrets).

### GitHub Secrets

| Secret | Description |
|---|---|
| `LI_API_TOKEN` | Linode API token (Read/Write for Linodes, StackScripts, Events, Firewalls) |
| `CF_API_TOKEN` | Cloudflare API token. Permissions: `Zone > DNS > Edit`, `Zone > SSL and Certificates > Edit` (issues the Origin CA cert), `Zone > Zone Settings > Edit` (enforces Full (Strict)), and `User > API Tokens > Edit` (self-rolls during rotation) |
| `TF_API_TOKEN` | Terraform Cloud API token |
| `LINODE_ROOT_PASSWORD` | Root password for the Linode instance |
| `GH_APP_PRIVATE_KEY` | GitHub App private key (for secret rotation) |

### GitHub Variables

| Variable | Description | Example |
|---|---|---|
| `CF_ZONE_ID` | Cloudflare zone ID | `a1b2c3...` |
| `CF_API_TOKEN_ID` | Cloudflare API token ID (32-char hex, from token list) | `d4e5f6...` |
| `TF_TEAM_ID` | Terraform Cloud team ID | `team-abc123...` |
| `GH_APP_ID` | GitHub App ID (from app settings) | `123456` |
| `DOMAIN` | Full domain for SearXNG | `search.example.com` |
| `TF_CLOUD_ORG` | Terraform Cloud organization name | `my-org` |
| `TF_CLOUD_WORKSPACE` | Terraform Cloud workspace name | `searxng-pipeline` |

## How It Works

1. **GitHub Actions** triggers on push to `main`, daily schedule, or manual dispatch
2. **Terraform** queries the Linode API for the latest Alpine image
3. An **Origin CA certificate** (ECDSA P-256) is generated for your domain, and the zone SSL mode is set to Full (Strict)
4. A **Linode Nanode 1GB** is provisioned with a StackScript that:
   - Installs Docker and nginx, and creates a swapfile
   - Writes the Origin CA cert/key for TLS
   - Configures nginx as a TLS 1.3 reverse proxy on port 443, recovering the real client IP from Cloudflare
   - Starts SearXNG (with the public-instance limiter) and a Valkey sidecar on localhost:8080
   - Waits for the backend to be healthy before starting nginx
5. A **Linode Firewall** is created allowing only Cloudflare IPv6 ranges on port 443
6. A **Cloudflare DNS** `AAAA` record points your domain to the instance IPv6 (proxied)
7. A **health check** polls the public URL and fails the deploy if the origin never comes up
8. Daily redeploy ensures the latest SearXNG and Alpine images, and updates Cloudflare IP ranges

## Deployment

### Automatic

Push to `main` triggers the pipeline:

```bash
git add .
git commit -m "deploy searxng"
git push origin main
```

### Manual

Trigger via the GitHub Actions UI using "Run workflow" on the `Deploy SearXNG` workflow.

### Local

```bash
cd terraform
export TF_VAR_linode_token="..."
export TF_VAR_cloudflare_api_token="..."
export TF_VAR_cloudflare_zone_id="..."
export TF_VAR_root_password="..."
export TF_VAR_domain="search.example.com"

# Terraform Cloud backend (NOT TF_VAR_*; these configure the cloud {} block)
export TF_CLOUD_ORGANIZATION="my-org"
export TF_WORKSPACE="searxng-pipeline"

# WARNING: deploy_timestamp drives replace_triggered_by. Leaving it unset (default "")
# changes it from the CI-set github.run_id and forces a destroy/recreate of the live
# instance on apply. Set it to the value the last CI run used to avoid that.
export TF_VAR_deploy_timestamp="<last github.run_id>"

terraform init
terraform plan
terraform apply
```

## Outputs

| Output | Description |
|---|---|
| `linode_ipv6` | Public IPv6 of the instance — the operative address (the firewall only admits Cloudflare over IPv6) |
| `linode_ip` | Public IPv4. **Non-serving**: all inbound IPv4 is dropped by the firewall; informational only |
| `searxng_url` | `https://<your-domain>` |

## Secret Rotation

Every 28 days, the `rotate-secrets.yml` workflow automatically rotates:

| Secret | Method |
|---|---|
| `LI_API_TOKEN` | Creates new Linode PAT, deletes old ones |
| `CF_API_TOKEN` | Rolls token via Cloudflare API (new value, same permissions) |
| `TF_API_TOKEN` | Generates new team token via Terraform Cloud API (revokes old one) |

After rotation, a deploy is triggered to apply the new credentials. The `CF_API_TOKEN` must have the permissions listed under [GitHub Secrets](#github-secrets), including `User > API Tokens > Edit` to allow self-rolling.

The Origin CA certificate is now issued using the `CF_API_TOKEN` (permission `Zone > SSL and Certificates > Edit`), not the legacy Origin CA user service key — that key is [deprecated by Cloudflare](https://developers.cloudflare.com/fundamentals/api/reference/deprecations/) and removed September 30, 2026, so it is no longer used here.

## Destroying

```bash
cd terraform
terraform destroy
```
