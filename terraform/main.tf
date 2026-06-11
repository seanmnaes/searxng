terraform {
  cloud {}

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "~> 3.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.19" # 5.19+ ships state upgraders for the v4->v5 resource renames
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # >= 1.8 required for cross-resource-type `moved` blocks (cloudflare_record -> cloudflare_dns_record)
  required_version = ">= 1.8.0"
}

provider "linode" {
  token = var.linode_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
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
  algorithm   = "ECDSA"
  ecdsa_curve = "P256" # Cloudflare Origin CA "origin-ecc" issues P-256 certs
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem

  subject {
    common_name = var.domain
  }
}

# Issued via the default provider's api_token (needs Zone > SSL and Certificates > Edit).
# Migrated off the deprecated Origin CA user service key, which Cloudflare removes 2026-09-30.
resource "cloudflare_origin_ca_certificate" "searxng" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = [var.domain]
  request_type       = "origin-ecc"
  requested_validity = 5475
}

# Enforce "Full (Strict)" SSL mode as code rather than a manual dashboard toggle, so the
# origin-cert trust model can't silently drift (Full = no origin validation; Flexible = outage).
# depends_on ensures the origin cert is issued before the mode flips to strict.
# Requires the api_token to have Zone > Zone Settings > Edit.
resource "cloudflare_zone_setting" "ssl" {
  zone_id    = var.cloudflare_zone_id
  setting_id = "ssl"
  value      = "strict"

  depends_on = [cloudflare_origin_ca_certificate.searxng]
}

# --- StackScript ---

resource "linode_stackscript" "searxng_setup" {
  label       = "searxng-docker-setup"
  description = "Install Docker, nginx, and run SearXNG with TLS"
  images      = [data.linode_images.alpine.images[0].id]
  script = join("\n", [
    "#!/bin/ash",
    # Fail fast on any error or unset variable so a half-broken boot does not silently
    # leave nginx proxying to a dead backend (which surfaces as a Cloudflare 521/502).
    "set -eu",
    "",
    "log() { echo \"[stackscript] $1\"; }",
    "",
    "apk update",
    "apk add docker docker-compose openrc nginx curl",
    "",
    "# Swap: the 1GB Nanode runs dockerd + nginx + SearXNG (+ Valkey) with image_proxy on.",
    "# A small swapfile prevents a burst from triggering a host-wide OOM kill.",
    "if [ ! -f /swapfile ]; then",
    "  fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024",
    "  chmod 600 /swapfile",
    "  mkswap /swapfile",
    "  swapon /swapfile",
    "  echo '/swapfile none swap sw 0 0' >> /etc/fstab",
    "  sysctl -w vm.swappiness=10",
    "fi",
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
    "    listen [::]:443 ssl;",
    "    http2 on;",
    "    server_name ${var.domain};",
    "    server_tokens off;",
    "    # Privacy: do not persist search queries (GET /search?q=...) or client IPs to disk.",
    "    access_log off;",
    "    ssl_certificate /etc/nginx/ssl/origin.pem;",
    "    ssl_certificate_key /etc/nginx/ssl/origin.key;",
    "    # TLS 1.3 only. Cloudflare's edge presents TLS 1.3 cipher suites to",
    "    # origins, so the Cloudflare->origin hop negotiates 1.3 cleanly.",
    "    ssl_protocols TLSv1.3;",
    "    ssl_prefer_server_ciphers off;",
    "    ssl_session_timeout 1d;",
    "    ssl_session_cache shared:searxng_ssl:10m;",
    "    ssl_session_tickets off;",
    "    # Clickjacking protection. SearXNG already emits X-Content-Type-Options and",
    "    # Referrer-Policy, so they are not re-added here to avoid duplicate headers.",
    "    add_header X-Frame-Options DENY always;",
    "    # Recover the real client IP from Cloudflare so the SearXNG limiter keys on the",
    "    # visitor, not the edge. CF-Connecting-IP is set by Cloudflare and trusted only",
    "    # from Cloudflare's published ranges.",
    join("\n", [for cidr in concat(data.cloudflare_ip_ranges.cloudflare.ipv4_cidrs, data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs) : "    set_real_ip_from ${cidr};"]),
    "    real_ip_header CF-Connecting-IP;",
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
    "# Start Docker and wait (bounded) for the daemon to be ready.",
    "rc-update add docker default",
    "service docker start",
    "i=0",
    "while ! docker info >/dev/null 2>&1; do",
    "  i=$((i+1))",
    "  [ \"$i\" -gt 60 ] && { log 'docker daemon did not become ready in 120s'; exit 1; }",
    "  sleep 2",
    "done",
    "log 'docker ready'",
    "",
    "mkdir -p /opt/searxng/settings",
    # Unquoted heredoc delimiter (SETTINGS) so $(...) runs and writes a fresh random
    # secret_key per boot. Do NOT quote it or the literal $(...) string is written.
    "cat > /opt/searxng/settings/settings.yml <<SETTINGS",
    "use_default_settings: true",
    "server:",
    "  secret_key: $(head -c 32 /dev/urandom | base64)",
    "  image_proxy: true",
    "  # Public-instance rate limiting / bot detection. Requires a reachable Valkey,",
    "  # else SearXNG exits on start (depends_on service_healthy below guarantees it).",
    "  limiter: true",
    "  public_instance: true",
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
    "valkey:",
    "  url: valkey://searxng-valkey:6379/0",
    "SETTINGS",
    "",
    # limiter.toml: trust nginx as a proxy so X-Forwarded-For is honored. nginx reaches
    # SearXNG over the Docker bridge, so its source falls in these private ranges.
    "cat > /opt/searxng/settings/limiter.toml <<'LIMITER'",
    "[botdetection]",
    "trusted_proxies = [",
    "  '127.0.0.0/8',",
    "  '::1',",
    "  '172.16.0.0/12',",
    "  '10.0.0.0/8',",
    "]",
    "LIMITER",
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
    "    mem_limit: 512m",
    "    depends_on:",
    "      valkey:",
    "        condition: service_healthy",
    "  valkey:",
    "    image: docker.io/valkey/valkey:9-alpine",
    "    container_name: searxng-valkey",
    "    command: valkey-server --save 30 1 --loglevel warning",
    "    restart: unless-stopped",
    "    mem_limit: 192m",
    "    volumes:",
    "      - valkey-data:/data",
    "    healthcheck:",
    "      test: [\"CMD\", \"valkey-cli\", \"ping\"]",
    "      interval: 5s",
    "      timeout: 3s",
    "      retries: 5",
    "volumes:",
    "  valkey-data:",
    "COMPOSE",
    "",
    "cd /opt/searxng",
    "docker compose pull",
    "docker compose up -d",
    "",
    "# Gate nginx on a healthy backend: poll SearXNG (bounded) before exposing :443.",
    "i=0",
    "while ! curl -fsS http://127.0.0.1:8080/ >/dev/null 2>&1; do",
    "  i=$((i+1))",
    "  [ \"$i\" -gt 60 ] && { log 'SearXNG did not become healthy in 180s'; docker compose logs --tail=50; exit 1; }",
    "  sleep 3",
    "done",
    "log 'SearXNG healthy'",
    "",
    "# Start nginx only after the backend is confirmed up.",
    "rc-update add nginx default",
    "service nginx start",
    "log 'boot complete'",
  ])
}

# --- Cloudflare IP Ranges ---

data "cloudflare_ip_ranges" "cloudflare" {}

# --- Linode Firewall ---

resource "linode_firewall" "searxng" {
  label = "cf-proxy"

  inbound {
    label    = "allow-cf-https"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "443"
    ipv6     = data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs
  }

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  linodes = [linode_instance.searxng.id]

  # Guard against a successful-but-empty IP-ranges response: with inbound_policy=DROP,
  # an empty allow list would black-hole all inbound :443 (full outage). Fail the apply instead.
  lifecycle {
    precondition {
      condition     = length(data.cloudflare_ip_ranges.cloudflare.ipv6_cidrs) > 0
      error_message = "Cloudflare IPv6 ranges are empty — refusing to apply a deny-all firewall."
    }
  }
}

# --- Linode Instance ---

resource "linode_instance" "searxng" {
  label     = "searxng"
  region    = "us-sea"
  type      = "g6-nanode-1"
  image     = data.linode_images.alpine.images[0].id
  root_pass = var.root_password

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

# Renamed from cloudflare_record in the v4 -> v5 provider upgrade. The v5
# provider's MoveState handler migrates existing state via this moved block,
# so the live DNS record is preserved (no destroy/recreate).
moved {
  from = cloudflare_record.searxng
  to   = cloudflare_dns_record.searxng
}

resource "cloudflare_dns_record" "searxng" {
  zone_id = var.cloudflare_zone_id
  name    = local.subdomain
  content = trimsuffix(linode_instance.searxng.ipv6, "/128")
  type    = "AAAA"
  ttl     = 1
  proxied = true
}
