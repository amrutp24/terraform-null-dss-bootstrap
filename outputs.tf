output "install_script" {
  description = "The rendered bootstrap script. Run it as root on any Linux host: pass it as EC2 user-data, a GCE startup script, an Azure custom script, a remote-exec payload, or a Packer provisioner."
  value       = local.install_script
  sensitive   = true # carries license_json when one was supplied

  # get-credentials needs both halves. With only one set the script renders
  # --zone "" and dies mid-boot, which is the exact class of failure the
  # variable validations exist to move to plan time.
  #
  # It lives on an output rather than in a validation block because a variable
  # validation could not look at another variable until Terraform 1.9, and this
  # module still supports 1.5.
  precondition {
    condition     = (var.gke_cluster_name == "") == (var.gke_cluster_zone == "")
    error_message = "gke_cluster_name and gke_cluster_zone must be set together; gcloud container clusters get-credentials needs both."
  }

  # build-base-image builds and pushes a container image, so it needs the
  # Docker daemon that containerized_execution installs. Asked for on its own
  # it renders a script that reaches dssadmin on a host with no docker command,
  # and because that step only warns, the instance comes up looking healthy
  # with no base image and nothing said about it until the first containerized
  # recipe fails.
  precondition {
    condition     = !var.build_base_image || var.containerized_execution
    error_message = "build_base_image needs containerized_execution = true: building the image requires the Docker daemon that installs."
  }
}

output "cloud_init" {
  description = "The same script wrapped as cloud-config, for targets that consume cloud-init directly."
  value       = local.cloud_init
  sensitive   = true
}

output "data_dir" {
  description = "DSS data directory on the host. Put a persistent disk here."
  value       = var.data_dir
}

output "dss_port" {
  description = "Port DSS listens on."
  value       = var.dss_port
}

output "api_key_path" {
  description = "Where the bootstrap wrote the admin API key, when create_api_key is set."
  value       = var.create_api_key ? var.api_key_path : null
}

output "url_path" {
  description = "Path to append to the host address to reach DSS, as a convenience for building the provider's host argument."
  value       = ":${var.dss_port}"
}
