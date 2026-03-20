terraform {
  cloud {}

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 2.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  required_version = ">= 1.5.0"
}

provider "linode" {
  token = var.linode_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "cloudflare" {
  alias                = "origin_ca"
  api_user_service_key = var.cloudflare_origin_ca_key
}

# --- Latest Alpine Image ---

data "linode_images" "alpine" {
  latest = true

  filter {
    name     = "label"
    values   = ["Alpine"]
    match_by = "substring"
  }

  filter {
    name   = "is_public"
    values = ["true"]
  }
}

# --- Origin CA Certificate ---

locals {
  subdomain = split(".", var.domain)[0]
}

resource "tls_private_key" "origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem

  subject {
    common_name = var.domain
  }
}

resource "cloudflare_origin_ca_certificate" "searxng" {
  provider           = cloudflare.origin_ca
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = [var.domain]
  request_type       = "origin-rsa"
  requested_validity = 5475
}

# --- StackScript ---

resource "linode_stackscript" "searxng_setup" {
  label       = "searxng-docker-setup"
  description = "Install Docker, nginx, and run SearXNG with TLS"
  images      = [data.linode_images.alpine.images[0].id]
  script = join("\n", [
    "#!/bin/ash",
    "apk update",
    "apk add docker docker-compose openrc nginx",
    "",
    "# Write TLS cert and key",
    "mkdir -p /etc/nginx/ssl",
    "echo '${base64encode(cloudflare_origin_ca_certificate.searxng.certificate)}' | base64 -d > /etc/nginx/ssl/origin.pem",
    "echo '${base64encode(tls_private_key.origin.private_key_pem)}' | base64 -d > /etc/nginx/ssl/origin.key",
    "chmod 600 /etc/nginx/ssl/origin.key",
    "",
    "# Configure nginx as TLS reverse proxy",
    "cat > /etc/nginx/http.d/searxng.conf <<'NGINX'",
    "server {",
    "    listen 443 ssl;",
    "    server_name ${var.domain};",
    "    ssl_certificate /etc/nginx/ssl/origin.pem;",
    "    ssl_certificate_key /etc/nginx/ssl/origin.key;",
    "    location / {",
    "        proxy_pass http://127.0.0.1:8080;",
    "        proxy_set_header Host $host;",
    "        proxy_set_header X-Real-IP $remote_addr;",
    "        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;",
    "        proxy_set_header X-Forwarded-Proto $scheme;",
    "    }",
    "}",
    "NGINX",
    "",
    "rm -f /etc/nginx/http.d/default.conf",
    "",
    "# Start Docker and SearXNG",
    "rc-update add docker default",
    "service docker start",
    "sleep 10",
    "while ! docker info >/dev/null 2>&1; do sleep 2; done",
    "",
    "mkdir -p /opt/searxng/settings",
    "cat > /opt/searxng/settings/settings.yml <<SETTINGS",
    "use_default_settings: true",
    "server:",
    "  secret_key: $(head -c 32 /dev/urandom | base64)",
    "  image_proxy: true",
    "ui:",
    "  default_theme: simple",
    "  theme_args:",
    "    simple_style: black",
    "  results_on_new_tab: true",
    "search:",
    "  default_lang: en",
    "  prefer_configured_language: true",
    "engines:",
    "  - name: mojeek",
    "    disabled: false",
    "  - name: yahoo",
    "    disabled: false",
    "  - name: duckduckgo",
    "    disabled: true",
    "plugins:",
    "  searx.plugins.infinite_scroll.SXNGPlugin:",
    "    active: true",
    "SETTINGS",
    "",
    "cat > /opt/searxng/docker-compose.yml <<'COMPOSE'",
    "services:",
    "  searxng:",
    "    image: docker.io/searxng/searxng:latest",
    "    container_name: searxng",
    "    restart: unless-stopped",
    "    ports:",
    "      - \"127.0.0.1:8080:8080\"",
    "    volumes:",
    "      - ./settings:/etc/searxng",
    "    environment:",
    "      - SEARXNG_BASE_URL=https://${var.domain}/",
    "COMPOSE",
    "",
    "cd /opt/searxng",
    "docker compose up -d",
    "",
    "# Start nginx after everything is ready",
    "rc-update add nginx default",
    "service nginx start",
  ])
}

# --- Linode Instance ---

resource "linode_instance" "searxng" {
  label           = "searxng"
  region          = "us-sea"
  type            = "g6-nanode-1"
  image           = data.linode_images.alpine.images[0].id
  root_pass       = var.root_password
  authorized_keys = [var.ssh_public_key]
  firewall_id     = var.linode_firewall_id

  stackscript_id   = linode_stackscript.searxng_setup.id
  stackscript_data = {}

  lifecycle {
    replace_triggered_by = [terraform_data.redeploy]
  }
}

resource "terraform_data" "redeploy" {
  input = var.deploy_timestamp
}

# --- Cloudflare DNS ---

resource "cloudflare_record" "searxng" {
  zone_id = var.cloudflare_zone_id
  name    = local.subdomain
  content = tolist(linode_instance.searxng.ipv4)[0]
  type    = "A"
  ttl     = 1
  proxied = true
}
