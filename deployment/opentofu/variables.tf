variable "hcloud_token" {
  description = "Hetzner Cloud API token."
  type        = string
  sensitive   = true
}

variable "server_name" {
  description = "Server name."
  type        = string
  default     = "hydra-srt-1"
}

variable "server_type" {
  description = "Hetzner server type."
  type        = string
  default     = "cax11"
}

variable "location" {
  description = "Hetzner location."
  type        = string
  default     = "fsn1"
}

variable "image" {
  description = "Base image."
  type        = string
  default     = "ubuntu-24.04"
}

variable "ssh_key_names" {
  description = "Existing Hetzner SSH key names to inject."
  type        = list(string)
}

variable "volume_name" {
  description = "Persistent data volume name."
  type        = string
  default     = "hydra-srt-data"
}

variable "volume_size_gb" {
  description = "Persistent data volume size in GB."
  type        = number
  default     = 20
}

variable "admin_ipv4_cidrs" {
  description = "IPv4 CIDRs allowed to SSH into the host."
  type        = list(string)
  default     = []
}

variable "admin_ipv6_cidrs" {
  description = "IPv6 CIDRs allowed to SSH into the host."
  type        = list(string)
  default     = []
}

variable "app_ipv4_cidrs" {
  description = "IPv4 CIDRs allowed to reach the Hydra UI/API port."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "app_ipv6_cidrs" {
  description = "IPv6 CIDRs allowed to reach the Hydra UI/API port."
  type        = list(string)
  default     = ["::/0"]
}

variable "app_port" {
  description = "Hydra UI/API TCP port."
  type        = number
  default     = 4000
}

variable "stream_ipv4_cidrs" {
  description = "IPv4 CIDRs allowed to reach listener streaming ports."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "stream_ipv6_cidrs" {
  description = "IPv6 CIDRs allowed to reach listener streaming ports."
  type        = list(string)
  default     = ["::/0"]
}

variable "stream_tcp_ports" {
  description = "Additional TCP listener ports to open for streaming."
  type        = list(number)
  default     = []
}

variable "stream_udp_ports" {
  description = "Additional UDP listener ports to open for streaming."
  type        = list(number)
  default     = []
}

variable "enable_ipv4" {
  description = "Whether to keep public IPv4 enabled."
  type        = bool
  default     = true
}

variable "enable_ipv6" {
  description = "Whether to keep public IPv6 enabled."
  type        = bool
  default     = true
}

variable "backups" {
  description = "Enable Hetzner server backups."
  type        = bool
  default     = false
}

variable "labels" {
  description = "Labels attached to the server and volume."
  type        = map(string)
  default = {
    app = "hydra-srt"
    env = "dev"
  }
}
