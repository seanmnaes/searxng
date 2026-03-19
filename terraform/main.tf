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

  connection {
    type     = "ssh"
    user     = "root"
    password = var.root_password
    host     = tolist(self.ipv4)[0]
  }

  provisioner "remote-exec" {
    inline = [
      "apk update",
      "apk add docker docker-compose openrc",
      "rc-update add docker default",
      "service docker start",
      "for i in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done",
      "mkdir -p /opt/searxng",
      "cat > /opt/searxng/docker-compose.yml <<'COMPOSE'\nservices:\n  searxng:\n    image: docker.io/searxng/searxng:latest\n    container_name: searxng\n    restart: unless-stopped\n    ports:\n      - \"80:8080\"\n    volumes:\n      - ./settings:/etc/searxng\n    environment:\n      - SEARXNG_BASE_URL=https://search.catlan.net/\nCOMPOSE",
      "cd /opt/searxng && docker compose up -d",
    ]
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
