# The variable validations exist to fail at plan time rather than halfway
# through a boot script on a machine nobody is watching. These check they
# actually fire.

variables {
  dss_version = "15.0.0"
}

run "rejects_a_version_that_is_not_semver" {
  command = plan

  variables {
    dss_version = "latest"
  }

  expect_failures = [var.dss_version]
}

run "rejects_a_partial_version" {
  command = plan

  variables {
    # The download URL is built from this, so "15.0" would 404 at boot.
    dss_version = "15.0"
  }

  expect_failures = [var.dss_version]
}

run "refuses_to_run_dss_as_root" {
  command = plan

  variables {
    dss_user = "root"
  }

  expect_failures = [var.dss_user]
}

run "rejects_a_privileged_port" {
  command = plan

  variables {
    # DSS runs unprivileged, so it could not bind this anyway.
    dss_port = 80
  }

  expect_failures = [var.dss_port]
}

run "rejects_a_port_above_the_valid_range" {
  command = plan

  variables {
    dss_port = 70000
  }

  expect_failures = [var.dss_port]
}

run "rejects_a_kubectl_version_without_its_leading_v" {
  command = plan

  variables {
    containerized_execution = true
    # dl.k8s.io serves /release/v1.31.0/..., so "1.31.0" is a 404 at boot.
    kubectl_version = "1.31.0"
  }

  expect_failures = [var.kubectl_version]
}

run "rejects_a_registry_url_where_a_host_belongs" {
  command = plan

  variables {
    # gcloud auth configure-docker takes a host. Given a URL it complains in a
    # way that does not point at the cause.
    gcloud_registry_host = "https://us-central1-docker.pkg.dev"
  }

  expect_failures = [var.gcloud_registry_host]
}

run "rejects_a_gke_cluster_without_its_zone" {
  command = plan

  variables {
    gke_cluster_name = "dss-elastic-ai"
  }

  # Checked on the output rather than the variable: a validation block could
  # not look at a second variable until Terraform 1.9, and this module supports
  # 1.5. See the precondition in outputs.tf.
  expect_failures = [output.install_script]
}

run "rejects_a_zone_without_a_gke_cluster" {
  command = plan

  variables {
    gke_cluster_zone = "us-central1-a"
  }

  expect_failures = [output.install_script]
}

run "accepts_a_valid_configuration" {
  command = plan

  variables {
    dss_version = "14.7.0"
    dss_port    = 10000
    dss_user    = "dataiku"
  }

  assert {
    condition     = strcontains(output.install_script, "DSS_VERSION=\"14.7.0\"")
    error_message = "A valid configuration should render without complaint."
  }
}
