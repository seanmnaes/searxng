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

resource "linode_instance" "searxng" {
  label           = "searxng"
  region          = "us-sea"
  type            = "g6-nanode-1"
  image           = data.linode_images.alpine.images[0].id
  root_pass       = var.root_password
  authorized_keys = [var.ssh_public_key]
  firewall_id     = 3495544

  metadata {
    user_data = base64encode(<<-EOF
      #!/bin/ash
      apk update
      apk add docker docker-compose openrc

      rc-update add docker default
      service docker start

      # Wait for Docker socket to be ready
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
            - "80:8080"
          volumes:
            - ./settings:/etc/searxng
          environment:
            - SEARXNG_BASE_URL=https://search.catlan.net/
      COMPOSE

      cd /opt/searxng
      docker compose up -d
    EOF
    )
  }

  lifecycle {
    replace_triggered_by = [terraform_data.redeploy]
  }
}

resource "terraform_data" "redeploy" {
  input = var.deploy_timestamp
}

resource "cloudflare_record" "searxng" {
  zone_id = var.cloudflare_zone_id
  name    = "search"
  content = tolist(linode_instance.searxng.ipv4)[0]
  type    = "A"
  ttl     = 1
  proxied = true
}
