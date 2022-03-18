# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


###############################################################################
#                                   Project                                   #
###############################################################################

module "project" {
  source          = "../../../modules/project"
  project_create  = var.project_create != null
  billing_account = try(var.project_create.billing_account, null)
  oslogin         = try(var.project_create.oslogin, false)
  parent          = try(var.project_create.parent, null)
  name            = var.project_id
  services = [
    "compute.googleapis.com",
    "networkconnectivity.googleapis.com"
  ]
  service_config = {
    disable_on_destroy         = false,
    disable_dependent_services = false
  }
}

################################################################################
#                                     VPCs                                     #
################################################################################

locals {
  onprem_region = keys(var.regions_config["onprem"])[0]
  onprem_subnet = module.vpc["onprem"].subnet_self_links["${local.onprem_region}/onprem-${local.onprem_region}-0"]
  admin_ranges  = flatten([
    for vpc in var.regions_config : [
      for ranges in vpc : ranges
    ]
  ])
}

module "vpc" {
  for_each   = var.regions_config
  source     = "../../../modules/net-vpc"
  project_id = module.project.project_id
  name       = each.key
  subnets = flatten([
    for region, ranges in each.value : [
      for idx, range in ranges : {
        name               = "${each.key}-${region}-${idx}"
        ip_cidr_range      = range
        region             = region
        secondary_ip_range = {}
      }
    ]
  ])
}

module "vpc-firewall" {
  for_each            = module.vpc
  source              = "../../../modules/net-vpc-firewall"
  project_id          = module.project.project_id
  network             = each.value.name
  admin_ranges        = local.admin_ranges
  http_source_ranges  = []
  https_source_ranges = []
}

module "hub-to-prod-peering" {
  source                     = "../../../modules/net-vpc-peering"
  local_network              = module.vpc["hub"].self_link
  peer_network               = module.vpc["prod"].self_link
  export_local_custom_routes = true
  export_peer_custom_routes  = false
}

module "hub-to-dev-peering" {
  count = contains(keys(module.vpc), "dev") ? 1 : 0
  source                     = "../../../modules/net-vpc-peering"
  local_network              = module.vpc["hub"].self_link
  peer_network               = module.vpc["dev"].self_link
  export_local_custom_routes = true
  export_peer_custom_routes  = false
  depends_on = [module.hub-to-prod-peering]
}

################################################################################
#                                 IPs and VPNs                                 #
################################################################################

# IPs for RAs in the hub and onprem. Although static, they could be dynamically
# reserved but the module "net-vpn-static" would fail ("for_each" dependency).
locals {
  ip_ra_hub = {for region, ranges in var.regions_config["hub"] :
    region => cidrhost(element(ranges, 0), 2)
  }

  # Using indexes is not ideal but enough to simulate the onprem DC. Here region
  # means destination of the RA tunnel, not where it is created.
  ip_ra_onprem = {for region, ranges in var.regions_config["hub"] :
    region => cidrhost(element(values(var.regions_config["onprem"])[0], 0),
      2 + index(keys(var.regions_config["hub"]), region))
  }
}

# Create IP addresses for RAs in the hub, one for each region.
resource "google_compute_address" "ra-hub" {
  for_each     = var.regions_config["hub"]
  name         = "ra-hub-${each.key}"
  project      = module.project.project_id
  region       = each.key
  subnetwork   = module.vpc["hub"].subnet_self_links["${each.key}/hub-${each.key}-0"]
  address_type = "INTERNAL"
  address      = local.ip_ra_hub[each.key]
}

# Create IP addresses for RAs in onprem (one region), as many as regions in the hub VPC.
resource "google_compute_address" "ra-onprem" {
  for_each     = var.regions_config["hub"]
  name         = "ra-onprem-${each.key}"
  project      = module.project.project_id
  region       = local.onprem_region
  subnetwork   = local.onprem_subnet
  address_type = "INTERNAL"
  address      = local.ip_ra_onprem[each.key]
}

# Create IP addresses for CRs in the hub, two IPs per CR. Wait for IP assignment for
# RAs in the hub is done to not 'steal' the IPs.
resource "google_compute_address" "cr-hub-1" {
  for_each     = var.regions_config["hub"]
  name         = "cr-hub-${each.key}-1"
  project      = module.project.project_id
  region       = each.key
  subnetwork   = module.vpc["hub"].subnet_self_links["${each.key}/hub-${each.key}-0"]
  address_type = "INTERNAL"
  depends_on   = [google_compute_address.ra-hub]
}

resource "google_compute_address" "cr-hub-2" {
  for_each     = var.regions_config["hub"]
  name         = "cr-hub-${each.key}-2"
  project      = module.project.project_id
  region       = each.key
  subnetwork   = module.vpc["hub"].subnet_self_links["${each.key}/hub-${each.key}-0"]
  address_type = "INTERNAL"
  depends_on   = [google_compute_address.ra-hub]
}

# Create IP addresses for VPN gateways in the hub, one for each region.
resource "google_compute_address" "vpn-hub" {
  for_each     = var.regions_config["hub"]
  name         = "vpn-hub-${each.key}"
  project      = module.project.project_id
  region       = each.key
  address_type = "EXTERNAL"
}

# There's only one region in the onprem VPC (simulating onprem DC), but we
# will create as many VPN gateways in onprem as regions in the hub VPC.
resource "google_compute_address" "vpn-onprem" {
  for_each     = var.regions_config["hub"]
  name         = "vpn-onprem-${each.key}"
  project      = module.project.project_id
  region       = local.onprem_region
  address_type = "EXTERNAL"
}

# We only want to establish Cloud VPN tunnels for RAs' IPs (see remote_ranges
# below). Almost all traffic should go through RA VPN tunnels.
module "vpn-hub-onprem" {
  for_each               = var.regions_config["hub"]
  source                 = "../../../modules/net-vpn-static"
  project_id             = module.project.project_id
  region                 = each.key
  network                = module.vpc["hub"].name
  name                   = "hub-${each.key}"
  remote_ranges          = ["${google_compute_address.ra-onprem[each.key].address}/32"]
  route_priority         = 0
  gateway_address_create = false
  gateway_address        = google_compute_address.vpn-hub[each.key].address
  tunnels = {
    onprem = {
      ike_version       = 2
      peer_ip           = google_compute_address.vpn-onprem[each.key].address
      shared_secret     = ""
      traffic_selectors = { local = ["0.0.0.0/0"], remote = null }
    }
  }
}

module "vpn-onprem-hub" {
  for_each               = var.regions_config["hub"]
  source                 = "../../../modules/net-vpn-static"
  project_id             = module.project.project_id
  region                 = local.onprem_region
  network                = module.vpc["onprem"].name
  name                   = "onprem-${each.key}"
  remote_ranges          = ["${google_compute_address.ra-hub[each.key].address}/32"]
  route_priority         = 0
  gateway_address_create = false
  gateway_address        = google_compute_address.vpn-onprem[each.key].address
  tunnels = {
    hub = {
      ike_version       = 2
      peer_ip           = google_compute_address.vpn-hub[each.key].address
      shared_secret     = module.vpn-hub-onprem[each.key].random_secret
      traffic_selectors = { local = ["0.0.0.0/0"], remote = null }
    }
  }
}

################################################################################
#                               Router Appliances                              #
################################################################################

locals {
  # Hub RAs. They peer with onhub RAs AND with CRs.
  # hub_ra_config = { for region, ranges in var.regions_config["hub"] : region => {
    # network = element(ranges, 0)
    # gateway = cidrhost(element(ranges, 0), 1)
    # # First free IP (host '2') of the routers' range is for the RA.
    # # The next two will be for the CR interfaces.
    # host      = cidrhost(element(ranges, 0), 2)
    # cr_peer_1 = cidrhost(element(ranges, 0), 3)
    # cr_peer_2 = cidrhost(element(ranges, 0), 4)
  # } }
  # We will use these same parameters thorughout all hub RAs. I think it will
  # work as long as the peers are different.
  _ra_bgp_network = "169.254.100.0/30"
  hub_ra_bgp_ip       = cidrhost(local._ra_bgp_network, 1) # 169.254.100.1
  # hub_ra_id          = "1.1.1.1"
  hub_asn            = "65001"
  cr_asn             = "65011"

  # Onprem RAs. Using indexes is not ideal but enough to simulate the onprem DC.
  # onprem_ra_network = element(values(var.regions_config["onprem"])[0], 0)
  # onprem_ra_config = { for region, ranges in var.regions_config["hub"] : region => {
  #   network = local.onprem_ra_network
  #   gateway = cidrhost(local.onprem_ra_network, 1)
  #   host = cidrhost(local.onprem_ra_network,
  #   2 + index(keys(var.regions_config["hub"]), region))
  # } }
  onprem_ra_bgp_ip       = cidrhost(local._ra_bgp_network, 2) # 169.254.100.2
  # onprem_ra_id          = "11.11.11.11"
  onprem_asn            = "65010"
}

# We instantiate as many routers in the DC as in the hub.
module "onprem-router" {
  for_each   = var.regions_config["hub"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${local.onprem_region}-b"
  name       = "onprem-ra-${each.key}"
  boot_disk = {
    image = "projects/sentrium-public/global/images/vyos-1-2-7"
    type  = "pd-balanced"
    size  = 10
  }
  can_ip_forward = true
  instance_type  = "n1-standard-2"
  metadata = {
    user-data = templatefile("${path.module}/config/cloud-init-onprem.tftpl", {
      # network       = "N" #local.onprem_ra_config[each.key].network
      network       = element(values(var.regions_config["onprem"])[0], 0)
      gateway       = "G" #local.onprem_ra_config[each.key].gateway
      host          = google_compute_address.ra-onprem[each.key].address
      peer          = google_compute_address.ra-hub[each.key].address
      router_id     = "ID" #local.onprem_ra_id
      bgp_ip        = local.onprem_ra_bgp_ip
      neighbor      = local.hub_ra_bgp_ip
      asn           = local.onprem_asn
      remote_asn    = local.hub_asn
    })
  }
  network_interfaces = [{
    network    = module.vpc["onprem"].self_link
    subnetwork = local.onprem_subnet
    nat        = false
    addresses = {
      internal = google_compute_address.ra-onprem[each.key].address
      external = null
    }
  }]
  service_account        = module.service-account-gce.email
  service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  tags                   = ["ssh"]
}

# We instantiate VyOS router VMs with cloud-init based configuration.
module "hub-router" {
  for_each   = var.regions_config["hub"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${each.key}-b"
  name       = "hub-ra-${each.key}"
  boot_disk = {
    image = "projects/sentrium-public/global/images/vyos-1-2-7"
    type  = "pd-balanced"
    size  = 10
  }
  can_ip_forward = true
  instance_type  = "n1-standard-2"
  metadata = {
    user-data = templatefile("${path.module}/config/cloud-init-hub.tftpl", {
      # network       = "N" #local.hub_ra_config[each.key].network
      network       = element(var.regions_config["hub"][each.key], 0)
      gateway       = "G" #local.hub_ra_config[each.key].gateway
      host          = google_compute_address.ra-hub[each.key].address
      peer          = google_compute_address.ra-onprem[each.key].address
      router_id     = "ID" #local.hub_ra_id
      bgp_ip        = local.hub_ra_bgp_ip
      neighbor      = local.onprem_ra_bgp_ip
      neighbor_cr_1 = google_compute_address.cr-hub-1[each.key].address
      neighbor_cr_2 = google_compute_address.cr-hub-2[each.key].address
      asn           = local.hub_asn
      cr_asn        = local.cr_asn
      remote_asn    = local.onprem_asn
    })
  }
  network_interfaces = [{
    network    = module.vpc["hub"].self_link
    subnetwork = module.vpc["hub"].subnet_self_links["${each.key}/hub-${each.key}-0"]
    nat        = false
    addresses = {
      internal = google_compute_address.ra-hub[each.key].address
      external = null
    }
  }]
  service_account        = module.service-account-gce.email
  service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  tags                   = ["ssh"]
}

################################################################################
#                                 Cloud Routers                                #
################################################################################

# Google provider doesn't support to add interfaces to a Cloud Router from a
# subnetwork, needed for creating a RA spoke in NCC. Using 'gcloud' for now.
/* module "cloud-router" {
  source  = "terraform-google-modules/gcloud/google"
  version = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers create hub-cr1 --project ${module.project.project_id}",
    "--region=europe-west1 --network=hub --asn=65011"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers delete hub-cr1 --project ${module.project.project_id}",
    "--region=europe-west1"
  ])
} */

/* module "cloud-router-interface-1" {
  source  = "terraform-google-modules/gcloud/google"
  version = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-interface hub-cr1 --project ${module.project.project_id}",
    "--interface-name=hub-router-1-0 --subnetwork=hub-europe-west1-1 --ip-address=10.0.0.19",
    "--region=europe-west1"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers remove-interface hub-cr1 --project ${module.project.project_id}",
    "--interface-name=hub-router-1-0 --region=europe-west1"
  ])
  module_depends_on = [module.cloud-router]
} */

/* module "cloud-router-interface-2" {
  source  = "terraform-google-modules/gcloud/google"
  version = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-interface hub-cr1 --project ${module.project.project_id}",
    "--interface-name=hub-router-1-1 --subnetwork=hub-europe-west1-1 --ip-address=10.0.0.20",
    "--redundant-interface=hub-router-1-0 --region=europe-west1"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers remove-interface hub-cr1 --project ${module.project.project_id}",
    "--interface-name=hub-router-1-1 --region=europe-west1"
  ])
  module_depends_on = [module.cloud-router-interface-1]
} */

/* module "cloud-router-bgp-1" {
  source  = "terraform-google-modules/gcloud/google"
  version = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-bgp-peer hub-cr1 --project ${module.project.project_id}",
    "--peer-name=hub-router-1-0 --interface=hub-router-1-0 --peer-ip-address=10.0.0.18",
    "--peer-asn=65001 --instance=hub-router --instance-zone=europe-west1-b",
    "--advertisement-mode=CUSTOM --set-advertisement-ranges=10.0.0.16/28",
    "--region=europe-west1"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers remove-bgp-peer hub-cr1 --project ${module.project.project_id}",
    "--peer-name=hub-router-1-0 --region=europe-west1"
  ])
  module_depends_on = [module.cloud-router-interface-2]
} */

/* module "cloud-router-bgp-2" {
  source  = "terraform-google-modules/gcloud/google"
  version = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-bgp-peer hub-cr1 --project ${module.project.project_id}",
    "--peer-name=hub-router-1-1 --interface=hub-router-1-1 --peer-ip-address=10.0.0.18",
    "--peer-asn=65001 --instance=hub-router --instance-zone=europe-west1-b",
    "--advertisement-mode=CUSTOM --set-advertisement-ranges=10.0.0.16/28",
    "--region=europe-west1"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers remove-bgp-peer hub-cr1 --project ${module.project.project_id}",
    "--peer-name=hub-router-1-1 --region=europe-west1"
  ])
  module_depends_on = [module.cloud-router-bgp-1]
} */

################################################################################
#                       Test VMs, one per region and VPC                       #
################################################################################

module "vm-hub" {
  for_each   = var.regions_config["hub"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${each.key}-b"
  name       = "hub-${each.key}"
  network_interfaces = [{
    network    = module.vpc["hub"].self_link
    subnetwork = module.vpc["hub"].subnet_self_links["${each.key}/hub-${each.key}-0"]
    nat        = false
    addresses  = null
  }]
  service_account        = module.service-account-gce.email
  service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  tags                   = ["ssh"]
}

module "vm-prod" {
  for_each   = var.regions_config["prod"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${each.key}-b"
  name       = "prod-${each.key}"
  network_interfaces = [{
    network    = module.vpc["prod"].self_link
    subnetwork = module.vpc["prod"].subnet_self_links["${each.key}/prod-${each.key}-0"]
    nat        = false
    addresses  = null
  }]
  service_account        = module.service-account-gce.email
  service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  tags                   = ["ssh"]
}

# Uncomment if you have a "dev" VPC spoke and want VMs there.
# module "vm-dev" {
#   for_each   = var.regions_config["dev"]
#   source     = "../../../modules/compute-vm"
#   project_id = module.project.project_id
#   zone       = "${each.key}-b"
#   name       = "dev-${each.key}"
#   network_interfaces = [{
#     network    = module.vpc["dev"].self_link
#     subnetwork = module.vpc["dev"].subnet_self_links["${each.key}/dev-${each.key}-0"]
#     nat        = false
#     addresses  = null
#   }]
#   service_account        = module.service-account-gce.email
#   service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
#   tags                   = ["ssh"]
# }

module "vm-onprem" {
  for_each   = var.regions_config["onprem"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${each.key}-b"
  name       = "onprem-${each.key}"
  network_interfaces = [{
    network    = module.vpc["onprem"].self_link
    subnetwork = local.onprem_subnet
    nat        = false
    addresses  = null
  }]
  service_account        = module.service-account-gce.email
  service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  tags                   = ["ssh"]
}

module "service-account-gce" {
  source     = "../../../modules/iam-service-account"
  project_id = module.project.project_id
  name       = "gce-test"
  iam_project_roles = {
    (module.project.project_id) = [
      "roles/logging.logWriter",
      "roles/monitoring.metricWriter",
    ]
  }
}

