# terraform-null-dss-bootstrap

Renders the script that installs [Dataiku DSS](https://www.dataiku.com/) on a
Linux host.

This module **creates no infrastructure and declares no provider**. It takes a
DSS version and some settings and gives back a shell script and a cloud-init
document. Where that runs is your choice, which is what keeps it usable on any
cloud, on bare metal, or in an image build.

```
┌─────────────────┐   install_script   ┌──────────────────┐   dataiku provider   ┌──────────────┐
│  this module    │ ─────────────────► │ compute you own  │ ───────────────────► │ projects,    │
│                 │                    │ VM / host / AMI  │                      │ code envs, … │
└─────────────────┘                    └──────────────────┘                      └──────────────┘
```

Most people want one of the modules that already wires this to a platform:

| | |
| --- | --- |
| AWS | [`amrutp24/dss/aws`](https://registry.terraform.io/modules/amrutp24/dss/aws) |
| GCP | [`amrutp24/dss/google`](https://registry.terraform.io/modules/amrutp24/dss/google) |
| Azure | [`amrutp24/dss/azurerm`](https://registry.terraform.io/modules/amrutp24/dss/azurerm) |

Use this one directly when your target is not among them.

Terraform >= 1.5. No providers, so nothing to install and nothing to
authenticate against.

## Usage

```hcl
module "bootstrap" {
  source  = "amrutp24/dss-bootstrap/null"
  version = "~> 0.1"

  dss_version  = "15.0.0"
  license_json = var.dss_license_json
}
```

Then hand `module.bootstrap.install_script` to whatever runs it.

## Outputs

| Output | Use |
| --- | --- |
| `install_script` | The rendered script. Run it as root on a Linux host. |
| `cloud_init` | The same script as cloud-config, for targets that take cloud-init. |
| `api_key_path` | Where the bootstrap left the admin key, or null when `create_api_key` is off. |
| `data_dir`, `dss_port`, `url_path` | Echoed back so callers can build a URL and pick a disk mount point. |

`install_script` and `cloud_init` are marked sensitive, because a `license_json`
you pass in is rendered into both. Re-exporting either from your own root module
needs `sensitive = true` on your output, or the plan fails.

## Wiring it to a target

The script wants to run as root on a fresh Linux host with outbound HTTPS.
Every target below consumes the same output.

**Any cloud VM that takes cloud-init**

```hcl
user_data = module.bootstrap.cloud_init
```

**EC2**

```hcl
resource "aws_instance" "dss" {
  user_data = module.bootstrap.install_script
}
```

**Compute Engine**

```hcl
resource "google_compute_instance" "dss" {
  metadata_startup_script = module.bootstrap.install_script
}
```

**Azure**

```hcl
resource "azurerm_linux_virtual_machine" "dss" {
  custom_data = base64encode(module.bootstrap.cloud_init)
}
```

**A host you already have, over SSH**

```hcl
resource "terraform_data" "dss" {
  connection {
    host = var.dss_host
    user = var.ssh_user
  }

  provisioner "remote-exec" {
    inline = ["sudo bash -c '${module.bootstrap.install_script}'"]
  }
}
```

**Baking an image with Packer**

Write `install_script` to a file and use it as a shell provisioner, so instances
boot with DSS already installed rather than downloading two gigabytes each time.

## What the script does

Follows Dataiku's documented install order: create the service user, download
and unpack, install OS dependencies, run `installer.sh` as that user, register
the boot service, start DSS.

The script is idempotent, which matters because cloud-init re-runs on reboot: it
checks for an existing data directory and exits rather than reinstalling over a
live one. DSS never runs as root. With `create_api_key` left on, the script waits
for the backend to answer before calling `dsscli`, so minting the key does not
race startup.

## Containerized execution (Elastic AI)

Off by default. `containerized_execution = true` also prepares the host to run
[containerized execution](https://doc.dataiku.com/dss/latest/containers/index.html):

```hcl
module "bootstrap" {
  source  = "amrutp24/dss-bootstrap/null"
  version = "~> 0.1"

  dss_version             = "15.0.0"
  containerized_execution = true
  kubectl_version         = "v1.31.0"
}
```

| Variable | Default | What it does |
| --- | --- | --- |
| `containerized_execution` | `false` | Installs a Docker daemon, adds `dss_user` to the `docker` group, installs kubectl. |
| `kubectl_version` | `""` | kubectl release, e.g. `v1.31.0`. Empty takes the current `stable`. |
| `gcloud_registry_host` | `""` | Installs the gcloud CLI and runs `gcloud auth configure-docker <host>` as the DSS user. |
| `gke_cluster_name` | `""` | Installs the gcloud CLI and fetches a kubeconfig for this cluster, as the DSS user. |
| `gke_cluster_zone` | `""` | Zone for the above. Set both or neither; a plan with one fails. |
| `build_base_image` | `false` | Runs `dssadmin build-base-image --type container-exec` after DSS is installed. |

Docker comes from Docker's own install script rather than the distribution
package, because on the RHEL family `dnf install docker` gives you
podman-docker and Dataiku states plainly that DSS is not compatible with
podman.

Dataiku requires that "the `docker` command on the DSS machine must be fully
functional and usable by the user running DSS", including access to the socket,
but does not say how to arrange it. The socket is `root:docker` mode 0660 on a
stock install, so the module puts `dss_user` in the `docker` group. That happens
before DSS starts, on purpose: supplementary groups are fixed when a process
starts, so granting the group to an already-running backend does nothing until
someone restarts it.

The two GCP variables are gated separately from `containerized_execution`, and
from each other, so the module stays cloud-neutral. Nothing GCP-specific is
rendered unless you ask for it, and the same script still boots on EC2, on
Azure, on bare metal and inside a Packer build.

`build_base_image` is its own variable because it is slow and pushes large
images. It runs last, after DSS is installed and answering, and a failure warns
rather than aborting: nothing else in the script depends on it and re-running it
is one command. The GKE credential fetch warns for the same kind of reason — a
cluster that Terraform is still creating, or a service account that does not yet
have `container.clusters.get`, should not kill a boot that already downloaded
1.9 GB. Everything else in this section aborts the boot on failure, because a
host that comes up looking healthy with no Docker daemon only reveals that when
somebody runs a recipe days later.

### What this does not do

- **It does not configure DSS.** Nothing here creates the containerized
  execution config, the Kubernetes cluster, the node pools, the registry, the
  service account or its IAM. Those belong in your cloud module and in the
  `dataiku` provider. This module only prepares the host.
- **It does not manage the cluster.** `gke_cluster_name` fetches a kubeconfig
  for a cluster you already have. There is no equivalent for EKS or AKS: for
  those, install the CLI yourself in your own user-data, or bake it into the
  image.
- **It assumes outbound internet.** `get.docker.com`, `dl.k8s.io` and
  `dl.google.com` are hardcoded, unlike `download_base_url`. An air-gapped host
  needs a machine image that already carries these tools; each install step is
  skipped when the command is already present, so that works.
- **It does not pin Docker.** Only kubectl has a version variable, because
  kubectl tolerates one minor version of skew from the cluster and will
  eventually stop talking to it.
- **It does not rerun on reboot.** The existing "DSS is already installed" guard
  exits before any of this, so a reboot does not reinstall Docker — and equally,
  turning `containerized_execution` on for an instance that is already up does
  nothing until you rebuild it or run the steps by hand.
- **It does not verify anything worked.** There is no post-install check that
  the DSS user can actually reach the socket.

## Getting the API key out

The [`dataiku` provider](https://registry.terraform.io/providers/amrutp24/dataiku/latest)
needs an API key, and on a brand-new instance the only way to mint one without a
browser is on the host itself. With `create_api_key` set, the bootstrap runs
`dsscli api-key-create` and writes the result to `api_key_path` as JSON, mode
0600.

`dsscli` writes an array of one object rather than a bare object, so whatever
reads the file has to index into it:

```json
[{ "id": "...", "key": "...", "label": "terraform", "description": "Managed by Terraform" }]
```

```bash
sudo python3 -c 'import json;print(json.load(open("/var/lib/dataiku-terraform-key.json"))[0]["key"])'
```

Retrieving it is the one genuinely platform-specific step, so this module leaves
it to you. A cloud secret manager is the cleanest option: extend the script to
push the key into Secrets Manager, Secret Manager or Key Vault, then read it back
with that provider's data source, so nothing sensitive passes through Terraform
state. Fetching the file over SSH with a `remote-exec` or an `external` data
source works too.

Or skip it entirely. Set `create_api_key = false` and create a global API key
under Administration → Security once the instance is up.

## Sizing

DSS drops into a low-memory mode below roughly 16 GB and says so in its logs.
The data directory holds every project and all configuration, so put it on a
persistent disk you back up, separate from the boot disk.

## Tests

```bash
terraform test
```

The module creates nothing, so every check happens at plan time against the
rendered script: no credentials, no cloud, no cleanup, and it runs in about a
second. Thirty-two cases, 64 assertions, covering the conditional blocks, the
reinstall guard, that the installer never runs as root, that the containerized
execution blocks are absent until asked for and correctly ordered when they are,
and that each variable validation actually fires on the input it is meant to
reject.

Assertions that name a command match line by line with everything from a `#`
onwards removed, so a comment mentioning the command cannot satisfy them. Two
weaker versions of that check passed against a script where the command had been
replaced by a comment naming it.

Two of those cases are regressions from real boots that failed after the 1.9 GB
download had already succeeded: a CRLF checkout turning the shebang into
`bash\r`, and package indexes stale enough that `install-deps.sh` could not find
a package that exists. Both are the kind of failure that only shows up on a real
machine, so both now have a test that fails without the fix.

## Licensing DSS

The `dataiku` provider talks to the DSS public REST API.

Whether a given instance serves it depends on the version and the licence, so
check rather than assume. A stock DSS 15 Community Edition answered the API with
no licence installed, and projects, groups, users, connections and scenarios were
all created through it. An older `dataiku/dss` container, by contrast, refused with `DSS API is not
available with your Free Edition license`.

The check that matters is whether the API answers at all:

```bash
curl -su "$DATAIKU_API_KEY:" "$DSS_URL/public/api/admin/general-settings/" -o /dev/null -w '%{http_code}'; echo
```

`200` means the provider will work. `401` is a bad key. A licence error names
itself in the body, and then you need a licence with API access.

Pass a licence with `license_json` if you have one, or register the instance
through its web interface on first visit.

`license_json` is rendered into the script, so it reaches instance metadata and
Terraform state. Supply it from a secret store rather than a file in your
repository.

## License

Mozilla Public License 2.0.
