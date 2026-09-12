variable "dss_version" {
  description = "DSS version to install, for example \"15.0.0\". Must exist under the download base URL."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.dss_version))
    error_message = "dss_version must look like 15.0.0."
  }
}

variable "dss_port" {
  description = "Base TCP port DSS listens on. DSS also uses a small range above this."
  type        = number
  default     = 10000

  validation {
    condition     = var.dss_port > 1024 && var.dss_port < 65000
    error_message = "dss_port must be an unprivileged port below 65000."
  }
}

variable "dss_user" {
  description = "Unix account DSS runs as. Created if missing. Never root."
  type        = string
  default     = "dataiku"

  validation {
    condition     = var.dss_user != "root"
    error_message = "DSS must not run as root."
  }
}

variable "install_dir" {
  description = "Where the DSS binaries are unpacked."
  type        = string
  default     = "/opt/dataiku"
}

variable "data_dir" {
  description = "DSS data directory. This holds all projects and configuration, so it is what you back up and what you put on a persistent disk."
  type        = string
  default     = "/data/dataiku/dss_data"
}

variable "download_base_url" {
  description = "Base URL the installer tarball is fetched from. Point this at an internal mirror for hosts without internet access."
  type        = string
  default     = "https://downloads.dataiku.com/public/studio"
}

variable "license_json" {
  description = <<-EOT
    Contents of a DSS licence file, applied at install time. Leave empty to
    register the instance through the browser instead.

    This lands in the rendered script, so it reaches Terraform state and
    whatever the script is passed to (instance metadata, user-data). Supply it
    from a secret store rather than a checked-in file.
  EOT
  type        = string
  default     = ""
  sensitive   = true
}

variable "create_api_key" {
  description = "Whether the bootstrap mints an admin API key so Terraform can then configure the instance. Without it you have to create a key by hand before the dataiku provider can do anything."
  type        = bool
  default     = true
}

variable "api_key_label" {
  description = "Label given to the API key the bootstrap creates."
  type        = string
  default     = "terraform"
}

variable "api_key_path" {
  description = "Path on the host the created API key is written to, as JSON, mode 0600. How you retrieve it is platform-specific; see the module README."
  type        = string
  default     = "/var/lib/dataiku-terraform-key.json"
}

variable "containerized_execution" {
  description = <<-EOT
    Whether the script also prepares the host for DSS containerized execution
    ("Elastic AI"): installs a Docker daemon, puts the DSS user in the docker
    group so it can reach the socket, and installs kubectl.

    Off by default, because it adds a Docker install to every boot of a host
    that may never run a container recipe.
  EOT
  type        = bool
  default     = false
}

variable "kubectl_version" {
  description = <<-EOT
    kubectl release to install, for example "v1.31.0". Empty takes whatever
    dl.k8s.io currently calls stable.

    Worth pinning. kubectl supports one minor version of skew from the cluster,
    so an unpinned bootstrap that worked in March can hand you a client too new
    for the same cluster in September. Only read when containerized_execution
    is set.
  EOT
  type        = string
  default     = ""

  validation {
    condition     = var.kubectl_version == "" || can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubectl_version))
    error_message = "kubectl_version must be empty or a release like v1.31.0; the dl.k8s.io path includes the leading v."
  }
}

variable "gcloud_registry_host" {
  description = <<-EOT
    Artifact Registry or GCR host to configure Docker credentials for, for
    example "us-central1-docker.pkg.dev". Setting it installs the gcloud CLI
    and runs `gcloud auth configure-docker` as the DSS user.

    Leave empty on every other cloud. Nothing GCP-specific is rendered unless
    this or gke_cluster_name is set.
  EOT
  type        = string
  default     = ""

  validation {
    # configure-docker takes a registry host, not a URL, and rejects a scheme
    # with a message that does not make the reason obvious.
    condition     = !can(regex("^[a-z]+://", var.gcloud_registry_host))
    error_message = "gcloud_registry_host is a host such as us-central1-docker.pkg.dev, not a URL."
  }
}

variable "gke_cluster_name" {
  description = "GKE cluster to fetch a kubeconfig for, as the DSS user, at the end of host preparation. Setting it installs the gcloud CLI. Requires gke_cluster_zone. Leave empty off GCP."
  type        = string
  default     = ""
}

variable "gke_cluster_zone" {
  description = "Zone of gke_cluster_name, passed to `gcloud container clusters get-credentials --zone`. Set both or neither."
  type        = string
  default     = ""
}

variable "build_base_image" {
  description = <<-EOT
    Whether the script runs `dssadmin build-base-image --type container-exec`
    once DSS is installed, so the first containerized recipe does not have to.

    Its own variable rather than part of containerized_execution because it is
    slow and pushes large images, and because a host whose Docker daemon came
    from the machine image may want the build without the rest. It needs a
    working Docker daemon from somewhere.
  EOT
  type        = bool
  default     = false
}
