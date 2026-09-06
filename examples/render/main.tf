# The module creates nothing. It renders the script, and you decide where it
# runs -- EC2 user-data, a GCE startup script, Azure custom-data, a remote-exec
# against a host you already own, or a Packer provisioner.

module "bootstrap" {
  source = "../../"

  dss_version = "15.0.0"
  data_dir    = "/data/dataiku/dss_data"
}

output "install_script" {
  description = "Run as root on any Linux host."
  value       = module.bootstrap.install_script
  sensitive   = true # carries license_json when one is supplied
}

output "cloud_init" {
  description = "The same script wrapped as cloud-config."
  value       = module.bootstrap.cloud_init
  sensitive   = true
}
