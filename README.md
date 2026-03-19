# SearXNG Pipeline

Automated deployment of [SearXNG](https://github.com/searxng/searxng) on Linode (Akamai) using Terraform and GitHub Actions, with Cloudflare DNS and proxy.

## Architecture

- **Compute**: Linode Nanode 1GB (`us-sea` region) running Alpine Linux (latest)
- **Application**: SearXNG Docker container (`docker.io/searxng/searxng:latest`)
- **DNS/Proxy**: Cloudflare proxied `A` record → `search.catlan.net`
- **State**: Terraform Cloud (`catlan/searxng-pipeline` workspace)
- **CI/CD**: GitHub Actions on push to `main`

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

1. Create an organization named `catlan` (or update `terraform/main.tf`)
2. Create a workspace named `searxng-pipeline`
3. Set execution mode to **Local**

### GitHub Secrets

| Secret | Description |
|---|---|
| `LI_API_TOKEN` | Linode API token |
| `CF_API_TOKEN` | Cloudflare API token (DNS edit permissions) |
| `TF_API_TOKEN` | Terraform Cloud API token |
| `LINODE_ROOT_PASSWORD` | Root password for the Linode instance |
| `SSH_PUBLIC_KEY` | SSH public key for instance access |

### GitHub Variables

| Variable | Description |
|---|---|
| `CF_ZONE_ID` | Cloudflare zone ID for `catlan.net` |

## How It Works

1. **GitHub Actions** triggers on push to `main` or manual dispatch
2. **Terraform** queries the Linode API for the latest Alpine image
3. A **Linode Nanode 1GB** is provisioned in `us-sea` with firewall `3495544`
4. A **StackScript** runs on first boot to install Docker and start SearXNG on port 80
5. A **Cloudflare DNS** `A` record is created/updated pointing `search.catlan.net` to the instance IP, proxied through Cloudflare for SSL and DDoS protection

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
export TF_VAR_ssh_public_key="ssh-ed25519 ..."

terraform init
terraform plan
terraform apply
```

## Outputs

| Output | Description |
|---|---|
| `linode_ip` | Public IP of the SearXNG instance |
| `searxng_url` | `https://search.catlan.net` |

## Destroying

To tear down all resources:

```bash
cd terraform
terraform destroy
```

Or add a `terraform destroy` step to the GitHub Actions workflow.
