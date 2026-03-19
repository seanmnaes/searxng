terraform {
  cloud {
    organization = "CatLan"
    workspaces {
      name = "searxng-pipeline"
    }
  }

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

variable "deploy_timestamp" {
  description = "Timestamp to force redeployment"
  type        = string
  default     = ""
}

# --- Origin CA Certificate ---

resource "tls_private_key" "origin" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "origin" {
  private_key_pem = tls_private_key.origin.private_key_pem

  subject {
    common_name = "search.catlan.net"
  }
}

resource "cloudflare_origin_ca_certificate" "searxng" {
  csr                = tls_cert_request.origin.cert_request_pem
  hostnames          = ["search.catlan.net"]
  request_type       = "origin-rsa"
  requested_validity = 5475 # 15 years
}

# --- StackScript ---

resource "linode_stackscript" "searxng_setup" {
  label       = "searxng-docker-setup"
  description = "Install Docker, nginx, and run SearXNG with TLS"
  images      = [data.linode_images.alpine.images[0].id]
  script      = <<-'EOF'
    #!/bin/ash
    # <UDF name="origin_cert" label="Origin CA Certificate" />
    # <UDF name="origin_key" label="Origin CA Private Key" />

    apk update
    apk add docker docker-compose openrc nginx

    # Write TLS cert and key
    mkdir -p /etc/nginx/ssl
    echo "$ORIGIN_CERT" > /etc/nginx/ssl/origin.pem
    echo "$ORIGIN_KEY" > /etc/nginx/ssl/origin.key
    chmod 600 /etc/nginx/ssl/origin.key

    # Configure nginx as TLS reverse proxy
    cat > /etc/nginx/http.d/searxng.conf <<'NGINX'
    server {
        listen 443 ssl;
        server_name search.catlan.net;

        ssl_certificate /etc/nginx/ssl/origin.pem;
        ssl_certificate_key /etc/nginx/ssl/origin.key;

        location / {
            proxy_pass http://127.0.0.1:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
        }
    }
    NGINX

    # Remove default nginx config
    rm -f /etc/nginx/http.d/default.conf

    # Start nginx
    rc-update add nginx default
    service nginx start

    # Start Docker and SearXNG
    rc-update add docker default
    service docker start

    for i in $(seq 1 30); do
      docker info >/dev/null 2>&1 && break
      sleep 2
    done

    mkdir -p /opt/searxng
    cat > /opt/searxng/docker-compose.yml <<'COMPOSE'
    services:
      searxng:
        image: docker.io/searxng/searxng:latest
        container_name: searxng
        restart: unless-stopped
        ports:
          - "127.0.0.1:8080:8080"
        volumes:
          - ./settings:/etc/searxng
        environment:
          - SEARXNG_BASE_URL=https://search.catlan.net/
    COMPOSE

    cd /opt/searxng
    docker compose up -d
  EOF
}

# --- Linode Instance ---

resource "linode_instance" "searxng" {
  label           = "searxng"
  region          = "us-sea"
  type            = "g6-nanode-1"
  image           = data.linode_images.alpine.images[0].id
  root_pass       = var.root_password
  authorized_keys = [var.ssh_public_key]
  firewall_id     = 3495544

  stackscript_id = linode_stackscript.searxng_setup.id
  stackscript_data = {
    origin_cert = cloudflare_origin_ca_certificate.searxng.certificate
    origin_key  = tls_private_key.origin.private_key_pem
  }

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
  name    = "search"
  content = tolist(linode_instance.searxng.ipv4)[0]
  type    = "A"
  ttl     = 1
  proxied = true
}
