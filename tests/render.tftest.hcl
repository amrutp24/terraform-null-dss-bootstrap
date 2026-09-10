# The module creates no infrastructure, so every check is a plan-time
# assertion on what the template rendered. That makes these tests fast and
# free: no provider, no credentials, nothing to destroy.

variables {
  dss_version = "15.0.0"
}

# Regression: a Windows clone with core.autocrlf=true checked the template out
# with CRLF, so the shebang rendered as "#!/usr/bin/env bash\r" and every boot
# died with "/usr/bin/env: 'bash\r': No such file or directory". Nothing here
# caught it, because startswith(script, "#!/usr/bin/env bash") is still true
# when the carriage return sits just past the match.
# Regression: install-deps.sh assumes current package indexes. A GCE Ubuntu
# 24.04 image's are stale, so it aborted on "Unable to locate package
# fonts-dejavu" after the 1.9 GB download had already succeeded.
run "refreshes_package_indexes_before_installing_dependencies" {
  command = plan

  # Everything from a '#' onwards is dropped before matching, so only a real
  # command counts. Two weaker versions of this check passed against a script
  # where the command had been replaced by a comment naming it: first a bare
  # strcontains over the whole script, then one that skipped only whole-line
  # comments and so still matched a trailing one.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "apt-get update")
    ])
    error_message = "Nothing refreshes apt's indexes, so install-deps.sh can fail to find packages that exist."
  }

  assert {
    condition = anytrue([
      for line in split("\n", split("scripts/install/install-deps.sh", output.install_script)[0]) :
      strcontains(split("#", line)[0], "apt-get update")
    ])
    error_message = "The refresh must come before install-deps.sh runs, or it is pointless."
  }

  assert {
    condition = alltrue([
      strcontains(output.install_script, "dnf makecache"),
      strcontains(output.install_script, "yum makecache"),
      strcontains(output.install_script, "zypper --non-interactive refresh"),
    ])
    error_message = "The refresh should cover the non-apt distributions install-deps.sh supports."
  }
}

run "carries_no_carriage_returns" {
  command = plan

  assert {
    condition     = !strcontains(output.install_script, "\r")
    error_message = "The script contains CR. A CRLF shebang makes Linux look for a command named 'bash\\r'."
  }

  assert {
    condition     = !strcontains(output.cloud_init, "\r")
    error_message = "The cloud-init document contains CR."
  }

  assert {
    condition     = startswith(output.install_script, "#!/usr/bin/env bash\n")
    error_message = "The shebang line must end at a bare newline."
  }
}

run "defaults_render_a_usable_script" {
  command = plan

  assert {
    condition     = startswith(output.install_script, "#!/usr/bin/env bash")
    error_message = "The script must start with a shebang to be usable as user-data."
  }

  assert {
    condition     = strcontains(output.install_script, "DSS_VERSION=\"15.0.0\"")
    error_message = "The requested version did not reach the script."
  }

  assert {
    condition     = strcontains(output.install_script, "https://downloads.dataiku.com/public/studio/$DSS_VERSION/$TARBALL")
    error_message = "The download URL is wrong; the installer would not be fetched."
  }

  assert {
    condition     = strcontains(output.install_script, "DSS_PORT=\"10000\"")
    error_message = "The default port did not reach the script."
  }

  assert {
    condition     = output.data_dir == "/data/dataiku/dss_data"
    error_message = "The data directory output does not match the default."
  }
}

run "refuses_to_reinstall_over_an_existing_instance" {
  command = plan

  # Cloud-init and startup scripts are re-run on reboot and on image rebuild,
  # so this guard is what stops a restart wiping a live data directory.
  assert {
    condition     = strcontains(output.install_script, "if [ -f \"$DATA_DIR/bin/dss\" ]; then")
    error_message = "The script must not reinstall over an existing data directory."
  }
}

run "never_runs_dss_as_root" {
  command = plan

  assert {
    condition     = strcontains(output.install_script, "sudo -u \"$DSS_USER\" \"$UNPACKED/installer.sh\"")
    error_message = "The installer must run as the service user, not as root."
  }
}

run "licence_is_written_and_passed_to_the_installer" {
  command = plan

  variables {
    license_json = "{\"licenseKind\":\"COMMUNITY\"}"
  }

  assert {
    condition     = strcontains(output.install_script, "{\"licenseKind\":\"COMMUNITY\"}")
    error_message = "The licence content was not written into the script."
  }

  assert {
    condition     = strcontains(output.install_script, "LICENSE_FLAG=\"-l $INSTALL_DIR/license.json\"")
    error_message = "A supplied licence must be passed to the installer with -l."
  }

  assert {
    condition     = strcontains(output.install_script, "-m 0600")
    error_message = "The licence file must not be world-readable."
  }
}

run "no_licence_means_no_licence_flag" {
  command = plan

  # license_json defaults to empty, so the conditional block must collapse
  # rather than emitting an empty -l flag that would break the installer.
  assert {
    condition     = strcontains(output.install_script, "LICENSE_FLAG=\"\"")
    error_message = "Without a licence the installer flag must be empty."
  }

  assert {
    condition     = !strcontains(output.install_script, "writing licence")
    error_message = "The licence block should not be rendered when none is supplied."
  }
}

run "api_key_is_created_by_default" {
  command = plan

  assert {
    condition     = strcontains(output.install_script, "dsscli\" api-key-create")
    error_message = "The bootstrap should mint the API key the provider needs."
  }

  assert {
    condition     = output.api_key_path == "/var/lib/dataiku-terraform-key.json"
    error_message = "The API key path output does not match the default."
  }

  assert {
    condition     = strcontains(output.install_script, "chmod 0600")
    error_message = "The API key file must not be world-readable."
  }
}

run "api_key_creation_can_be_turned_off" {
  command = plan

  variables {
    create_api_key = false
  }

  assert {
    condition     = !strcontains(output.install_script, "api-key-create")
    error_message = "No key should be created when create_api_key is false."
  }

  assert {
    condition     = output.api_key_path == null
    error_message = "api_key_path must be null when no key is created."
  }
}

run "waits_for_the_backend_before_using_dsscli" {
  command = plan

  # dsscli talks to the running backend, so minting a key immediately after
  # starting DSS races its startup.
  assert {
    condition     = strcontains(output.install_script, "waiting for the DSS backend")
    error_message = "The script must wait for the backend before calling dsscli."
  }
}

run "cloud_init_wraps_the_same_script" {
  command = plan

  assert {
    condition     = startswith(output.cloud_init, "#cloud-config")
    error_message = "cloud_init must be a cloud-config document."
  }

  assert {
    condition     = strcontains(output.cloud_init, "/opt/dss-bootstrap.sh")
    error_message = "cloud-init must write and then run the script."
  }

  assert {
    condition     = strcontains(output.cloud_init, "DSS_VERSION=\"15.0.0\"")
    error_message = "The script embedded in cloud-init lost its variables."
  }
}

run "containerized_execution_renders_nothing_by_default" {
  command = plan

  # The feature is opt-in, so an existing caller who upgrades this module must
  # get a byte-identical script. These strings appear nowhere else in the
  # template, comments included, so a plain strcontains is the strict check
  # here rather than the loose one.
  assert {
    condition = alltrue([
      !strcontains(output.install_script, "docker"),
      !strcontains(output.install_script, "kubectl"),
      !strcontains(output.install_script, "gcloud"),
      !strcontains(output.install_script, "build-base-image"),
    ])
    error_message = "Containerized-execution setup leaked into the default script."
  }
}

run "containerized_execution_installs_docker_and_kubectl" {
  command = plan

  variables {
    containerized_execution = true
  }

  # Comment-stripped, for the reason given at the top of this file: a comment
  # naming the command must not be able to satisfy an assertion about it.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "sh /tmp/get-docker.sh")
    ])
    error_message = "Nothing installs a Docker daemon, which containerized execution requires."
  }

  # Dataiku says DSS is not compatible with podman, and on the RHEL family the
  # distribution's "docker" package is podman-docker. Docker's own script is
  # what gets docker-ce, so pin the assertion to it.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "https://get.docker.com")
    ])
    error_message = "Docker must come from Docker, not from a distribution package that may be podman."
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "systemctl enable docker")
    ])
    error_message = "The Docker daemon must be enabled, or it will not be there after the first reboot."
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "/usr/local/bin/kubectl")
    ])
    error_message = "Nothing installs kubectl."
  }

  # Left unpinned the script has to ask dl.k8s.io what stable means today.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "https://dl.k8s.io/release/stable.txt")
    ])
    error_message = "With no kubectl_version the script must resolve the current stable release."
  }

  # Nothing above is GCP-specific, so a plain Docker plus kubectl host must
  # render without a trace of Google.
  assert {
    condition     = !strcontains(output.install_script, "gcloud")
    error_message = "GCP wiring rendered without any GCP variable being set."
  }
}

run "a_pinned_kubectl_version_is_used_verbatim" {
  command = plan

  variables {
    containerized_execution = true
    kubectl_version         = "v1.31.0"
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "KUBECTL_VERSION=\"v1.31.0\"")
    ])
    error_message = "The pinned kubectl version did not reach the script."
  }
}

run "the_dss_user_joins_the_docker_group_before_dss_starts" {
  command = plan

  variables {
    containerized_execution = true
  }

  # Dataiku's requirements say the docker command must be usable by the user
  # running DSS, but never say how. The socket is root:docker 0660, so this is
  # the step that actually satisfies it.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "usermod -aG docker \"$DSS_USER\"")
    ])
    error_message = "The DSS user is not in the docker group, so DSS cannot reach the socket."
  }

  # Supplementary groups are fixed when a process starts. Adding the group
  # after "dss start" leaves a backend that is denied the socket until someone
  # restarts it, and "groups dataiku" looks correct the whole time.
  assert {
    condition = anytrue([
      for line in split("\n", split("\"$DATA_DIR/bin/dss\" start", output.install_script)[0]) :
      strcontains(split("#", line)[0], "usermod -aG docker")
    ])
    error_message = "The docker group must be granted before DSS is started, or the running backend never picks it up."
  }

  # groupadd first, because docker may already be present from the machine
  # image without the group; usermod would then abort the boot.
  assert {
    condition = anytrue([
      for line in split("\n", split("usermod -aG docker", output.install_script)[0]) :
      strcontains(split("#", line)[0], "groupadd docker")
    ])
    error_message = "usermod runs before anything guarantees the docker group exists."
  }
}

run "gcp_wiring_needs_its_own_variables" {
  command = plan

  variables {
    # Containerized execution on its own must stay cloud-neutral: this same
    # script has to boot on EC2, on Azure and on bare metal.
    containerized_execution = true
  }

  assert {
    condition = alltrue([
      !strcontains(output.install_script, "gcloud"),
      !strcontains(output.install_script, "configure-docker"),
      !strcontains(output.install_script, "get-credentials"),
      !strcontains(output.install_script, "dl.google.com"),
    ])
    error_message = "Containerized execution must not drag GCP-specific commands into the script."
  }
}

run "a_registry_host_configures_docker_credentials_only" {
  command = plan

  variables {
    containerized_execution = true
    gcloud_registry_host    = "us-central1-docker.pkg.dev"
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "gcloud auth configure-docker --quiet \"us-central1-docker.pkg.dev\"")
    ])
    error_message = "The registry host did not reach gcloud auth configure-docker."
  }

  # -H is load-bearing: without it sudo keeps HOME=/root and the credential
  # helper config lands where the DSS user will never read it.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "sudo -u \"$DSS_USER\" -H gcloud auth configure-docker")
    ])
    error_message = "configure-docker must run as the DSS user with its own HOME."
  }

  # Each GCP variable gates its own step, so a registry host alone must not
  # pull in a cluster it was never told about.
  assert {
    condition     = !strcontains(output.install_script, "gcloud container clusters get-credentials")
    error_message = "A registry host must not trigger a GKE credential fetch."
  }
}

run "a_gke_cluster_fetches_credentials_only" {
  command = plan

  variables {
    containerized_execution = true
    gke_cluster_name        = "dss-elastic-ai"
    gke_cluster_zone        = "us-central1-a"
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "sudo -u \"$DSS_USER\" -H gcloud container clusters get-credentials")
    ])
    error_message = "The kubeconfig must be fetched as the DSS user with its own HOME."
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "\"dss-elastic-ai\" --zone \"us-central1-a\"")
    ])
    error_message = "The cluster name and zone did not reach get-credentials."
  }

  # A cluster that is still being created, or a service account without
  # container.clusters.get, must not kill a boot that has already downloaded
  # 1.9 GB and installed DSS.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "warning: could not fetch GKE credentials")
    ])
    error_message = "A failed credential fetch must warn rather than abort the boot."
  }

  assert {
    condition     = !strcontains(output.install_script, "configure-docker")
    error_message = "A cluster must not trigger registry credential configuration."
  }
}

run "the_base_image_build_is_separately_opt_in" {
  command = plan

  variables {
    containerized_execution = true
  }

  assert {
    condition     = !strcontains(output.install_script, "build-base-image")
    error_message = "The slow base-image build must not come along with containerized_execution."
  }
}

run "the_base_image_is_built_after_dss_is_installed" {
  command = plan

  variables {
    # Deliberately without containerized_execution: the build is its own
    # variable so a host whose Docker came from the machine image can have it.
    build_base_image = true
  }

  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "./bin/dssadmin build-base-image --type container-exec")
    ])
    error_message = "The base image is not built."
  }

  # dssadmin only exists once installer.sh has created the data directory, so
  # a build placed earlier would fail on a missing file every single boot.
  assert {
    condition = !anytrue([
      for line in split("\n", split("\"$UNPACKED/installer.sh\"", output.install_script)[0]) :
      strcontains(split("#", line)[0], "dssadmin build-base-image")
    ])
    error_message = "The base image build must not run before installer.sh has created the data directory."
  }

  # Dataiku documents this as run from the data directory as the DSS user.
  assert {
    condition = anytrue([
      for line in split("\n", output.install_script) :
      strcontains(split("#", line)[0], "sudo -u \"$DSS_USER\" -H sh -c \"cd '$DATA_DIR' && ./bin/dssadmin build-base-image")
    ])
    error_message = "The base image must be built as the DSS user from the data directory."
  }
}

run "containerized_execution_carries_no_carriage_returns" {
  command = plan

  # The CRLF regression is not a one-off property of the original template: any
  # block added later can reintroduce it, and it fails on a machine nobody is
  # watching. Check the largest script this module can render.
  variables {
    containerized_execution = true
    gcloud_registry_host    = "us-central1-docker.pkg.dev"
    gke_cluster_name        = "dss-elastic-ai"
    gke_cluster_zone        = "us-central1-a"
    build_base_image        = true
    license_json            = "{\"licenseKind\":\"COMMUNITY\"}"
  }

  assert {
    condition     = !strcontains(output.install_script, "\r")
    error_message = "The script contains CR with containerized execution enabled."
  }

  assert {
    condition     = !strcontains(output.cloud_init, "\r")
    error_message = "The cloud-init document contains CR with containerized execution enabled."
  }
}

run "custom_paths_and_port_are_honoured" {
  command = plan

  variables {
    dss_port          = 11000
    dss_user          = "dku"
    install_dir       = "/srv/dataiku"
    data_dir          = "/mnt/disks/dss"
    download_base_url = "https://mirror.internal/dss"
  }

  assert {
    condition = alltrue([
      strcontains(output.install_script, "DSS_PORT=\"11000\""),
      strcontains(output.install_script, "DSS_USER=\"dku\""),
      strcontains(output.install_script, "INSTALL_DIR=\"/srv/dataiku\""),
      strcontains(output.install_script, "DATA_DIR=\"/mnt/disks/dss\""),
      strcontains(output.install_script, "https://mirror.internal/dss/$DSS_VERSION/$TARBALL"),
    ])
    error_message = "A custom path, port or mirror did not reach the script."
  }

  assert {
    condition     = output.dss_port == 11000
    error_message = "The port output does not follow the variable."
  }
}
