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
second. Eighteen cases, 30 assertions, covering the conditional blocks, the
reinstall guard, that the installer never runs as root, and that each variable
validation actually fires on the input it is meant to reject.

Two of those cases are regressions from real boots that failed after the 1.9 GB
download had already succeeded: a CRLF checkout turning the shebang into
`bash\r`, and package indexes stale enough that `install-deps.sh` could not find
a package that exists. Both are the kind of failure that only shows up on a real
machine, so both now have a test that fails without the fix.

## Licensing DSS

The `dataiku` provider talks to the DSS public REST API, and the Free Edition
does not licence that on its own. The Enterprise trial bundled with it does, for
as long as the trial lasts. Pass a licence with `license_json`, or register the
instance through its web interface on first visit.

`license_json` is rendered into the script, so it reaches instance metadata and
Terraform state. Supply it from a secret store rather than a file in your
repository.

## License

Mozilla Public License 2.0.
