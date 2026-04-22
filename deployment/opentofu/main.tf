provider "hcloud" {
  token = var.hcloud_token
}

locals {
  firewall_name            = "${var.server_name}-edge"
  volume_linux_device_path = "/dev/disk/by-id/scsi-0HC_Volume_${var.volume_name}"
  app_port_string          = tostring(var.app_port)
  stream_tcp_port_strings  = [for port in var.stream_tcp_ports : tostring(port)]
  stream_udp_port_strings  = [for port in var.stream_udp_ports : tostring(port)]
}

resource "hcloud_firewall" "edge" {
  name = local.firewall_name

  dynamic "rule" {
    for_each = concat(var.admin_ipv4_cidrs, var.admin_ipv6_cidrs)

    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = [rule.value]
    }
  }

  dynamic "rule" {
    for_each = concat(var.app_ipv4_cidrs, var.app_ipv6_cidrs)

    content {
      direction  = "in"
      protocol   = "tcp"
      port       = local.app_port_string
      source_ips = [rule.value]
    }
  }

  dynamic "rule" {
    for_each = {
      for pair in setproduct(local.stream_tcp_port_strings, concat(var.stream_ipv4_cidrs, var.stream_ipv6_cidrs)) :
      "${pair[0]}-${pair[1]}" => {
        port = pair[0]
        cidr = pair[1]
      }
    }

    content {
      direction  = "in"
      protocol   = "tcp"
      port       = rule.value.port
      source_ips = [rule.value.cidr]
    }
  }

  dynamic "rule" {
    for_each = {
      for pair in setproduct(local.stream_udp_port_strings, concat(var.stream_ipv4_cidrs, var.stream_ipv6_cidrs)) :
      "${pair[0]}-${pair[1]}" => {
        port = pair[0]
        cidr = pair[1]
      }
    }

    content {
      direction  = "in"
      protocol   = "udp"
      port       = rule.value.port
      source_ips = [rule.value.cidr]
    }
  }

  labels = var.labels
}

resource "hcloud_server" "this" {
  name        = var.server_name
  server_type = var.server_type
  image       = var.image
  location    = var.location
  backups     = var.backups
  ssh_keys    = var.ssh_key_names
  firewall_ids = [
    hcloud_firewall.edge.id,
  ]

  public_net {
    ipv4_enabled = var.enable_ipv4
    ipv6_enabled = var.enable_ipv6
  }

  labels = var.labels

  user_data = templatefile("${path.module}/../cloud-init/cloud-init.yaml.tftpl", {
    admin_ipv4_cidrs         = var.admin_ipv4_cidrs
    admin_ipv6_cidrs         = var.admin_ipv6_cidrs
    app_ipv4_cidrs           = var.app_ipv4_cidrs
    app_ipv6_cidrs           = var.app_ipv6_cidrs
    app_port                 = var.app_port
    stream_ipv4_cidrs        = var.stream_ipv4_cidrs
    stream_ipv6_cidrs        = var.stream_ipv6_cidrs
    stream_tcp_ports         = local.stream_tcp_port_strings
    stream_udp_ports         = local.stream_udp_port_strings
    volume_linux_device_path = local.volume_linux_device_path
  })
}

resource "hcloud_volume" "data" {
  name     = var.volume_name
  location = var.location
  size     = var.volume_size_gb
  format   = "ext4"
  labels   = var.labels

  lifecycle {
    prevent_destroy = true
  }
}

resource "hcloud_volume_attachment" "data" {
  server_id = hcloud_server.this.id
  volume_id = hcloud_volume.data.id
  automount = false
}
