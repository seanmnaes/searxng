# SearXNG Pipeline

Automated deployment of [SearXNG](https://github.com/searxng/searxng) on Linode (Akamai) using Terraform and GitHub Actions, with Cloudflare DNS, proxy, and Origin CA TLS.

## Architecture

- **Compute**: Linode Nanode 1GB running Alpine Linux (latest)
- **Application**: SearXNG Docker container (`docker.io/searxng/searxng:latest`)
- **TLS**: Cloudflare Origin CA certificate with nginx reverse proxy
- **DNS/Proxy**: Cloudflare proxied `A` record
- **State**: Terraform Cloud
- **CI/CD**: GitHub Actions on push to `main` + daily redeploy at 04:00 PDT

## Project Structure

```
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions pipeline
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

1. Set SSL/TLS mode to **Full (Strict)**
2. Ensure your firewall allows inbound TCP port 443

### GitHub Secrets

| Secret | Description |
|---|---|
| `LI_API_TOKEN` | Linode API token (Read/Write for Linodes, StackScripts, Events) |
| `CF_API_TOKEN` | Cloudflare API token (DNS edit permissions) |
| `CF_ORIGIN_CA_KEY` | Cloudflare Origin CA key ([Profile → API Tokens](https://dash.cloudflare.com/profile/api-tokens)) |
| `TF_API_TOKEN` | Terraform Cloud API token |
| `LINODE_ROOT_PASSWORD` | Root password for the Linode instance |

### GitHub Variables

| Variable | Description | Example |
|---|---|---|
| `CF_ZONE_ID` | Cloudflare zone ID | `a1b2c3...` |
| `DOMAIN` | Full domain for SearXNG | `search.example.com` |
| `TF_CLOUD_ORG` | Terraform Cloud organization name | `my-org` |
| `TF_CLOUD_WORKSPACE` | Terraform Cloud workspace name | `searxng-pipeline` |

## How It Works

1. **GitHub Actions** triggers on push to `main`, daily schedule, or manual dispatch
2. **Terraform** queries the Linode API for the latest Alpine image
3. An **Origin CA certificate** is generated for your domain
4. A **Linode Nanode 1GB** is provisioned with a StackScript that:
   - Installs Docker and nginx
   - Writes the Origin CA cert/key for TLS
   - Configures nginx as a TLS reverse proxy on port 443
   - Starts SearXNG on localhost:8080
5. A **Linode Firewall** is created allowing only Cloudflare IPv6 ranges on port 443
6. A **Cloudflare DNS** `AAAA` record points your domain to the instance IPv6 (proxied)
7. Daily redeploy ensures the latest SearXNG and Alpine images, and updates Cloudflare IP ranges

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
export TF_VAR_cloudflare_origin_ca_key="..."
export TF_VAR_cloudflare_zone_id="..."
export TF_VAR_root_password="..."
export TF_VAR_domain="search.example.com"
export TF_VAR_tf_cloud_organization="my-org"
export TF_VAR_tf_cloud_workspace="searxng-pipeline"

terraform init
terraform plan
terraform apply
```

## Outputs

| Output | Description |
|---|---|
| `linode_ip` | Public IP of the SearXNG instance |
| `searxng_url` | `https://<your-domain>` |

## Destroying

```bash
cd terraform
terraform destroy
```
