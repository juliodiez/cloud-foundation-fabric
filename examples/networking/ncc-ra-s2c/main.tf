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
  onprem_subnet = module.vpc["onprem"].subnet_self_links[
  "${local.onprem_region}/onprem-${local.onprem_region}-0"]
  admin_ranges = flatten([
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
  source                     = "../../../modules/net-vpc-peering"
  local_network              = module.vpc["hub"].self_link
  peer_network               = module.vpc["dev"].self_link
  export_local_custom_routes = true
  export_peer_custom_routes  = false
  depends_on                 = [module.hub-to-prod-peering]
}

################################################################################
#                                 IPs and VPNs                                 #
################################################################################

# IPs for RAs in the hub and onprem. Although static, if they are dynamically
# reserved the module "net-vpn-static" would fail ("for_each" dependency).
locals {
  ip_ra_hub = { for region, ranges in var.regions_config["hub"] :
    region => cidrhost(element(ranges, 0), 2)
  }

  # Using indexes is not ideal but enough to simulate the onprem DC. Here region
  # means destination of the RA tunnel, not where it is created.
  ip_ra_onprem = { for region, ranges in var.regions_config["hub"] :
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
  hub_ra_bgp_ip    = cidrhost(var.bgp_network, 1) # e.g. 169.254.0.1
  onprem_ra_bgp_ip = cidrhost(var.bgp_network, 2) # e.g. 169.254.0.2
}

# We instantiate VyOS router VMs with cloud-init based configuration.
module "hub-router" {
  for_each   = var.regions_config["hub"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${each.key}-b"
  name       = "hub-ra-${each.key}"
  boot_disk = {
    image = "projects/sentrium-public/global/images/vyos-1-3-0"
    type  = "pd-balanced"
    size  = 10
  }
  can_ip_forward = true
  instance_type  = "n1-standard-2"
  metadata = {
    serial-port-enable = "TRUE"
    user-data = templatefile("${path.module}/config/cloud-init-hub.tftpl", {
      network       = element(var.regions_config["hub"][each.key], 0)
      gateway       = cidrhost(element(var.regions_config["hub"][each.key], 0), 1)
      host          = google_compute_address.ra-hub[each.key].address
      peer          = google_compute_address.ra-onprem[each.key].address
      bgp_ip        = local.hub_ra_bgp_ip
      neighbor      = local.onprem_ra_bgp_ip
      neighbor_cr_1 = google_compute_address.cr-hub-1[each.key].address
      neighbor_cr_2 = google_compute_address.cr-hub-2[each.key].address
      asn           = var.gcp-asn-ra
      cr_asn        = var.gcp-asn-cr
      remote_asn    = var.onprem-asn
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

# We instantiate as many router VMs in the DC as in the hub.
module "onprem-router" {
  for_each   = var.regions_config["hub"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${local.onprem_region}-b"
  name       = "onprem-ra-${each.key}"
  boot_disk = {
    image = "projects/sentrium-public/global/images/vyos-1-3-0"
    type  = "pd-balanced"
    size  = 10
  }
  can_ip_forward = true
  instance_type  = "n1-standard-2"
  metadata = {
    serial-port-enable = "TRUE"
    user-data = templatefile("${path.module}/config/cloud-init-onprem.tftpl", {
      network    = element(values(var.regions_config["onprem"])[0], 0)
      gateway    = cidrhost(element(values(var.regions_config["onprem"])[0], 0), 1)
      host       = google_compute_address.ra-onprem[each.key].address
      peer       = google_compute_address.ra-hub[each.key].address
      bgp_ip     = local.onprem_ra_bgp_ip
      neighbor   = local.hub_ra_bgp_ip
      asn        = var.onprem-asn
      remote_asn = var.gcp-asn-ra
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

# The onprem router will learn how to reach GCP via BGP, but for convenience we
# make this work with summarized static routes in the VPC.
resource "google_compute_route" "route-to-gcp" {
  for_each          = var.regions_blocks
  name              = "route-to-gcp-${each.key}"
  project           = module.project.project_id
  dest_range        = each.value
  network           = module.vpc["onprem"].name
  next_hop_instance = module.onprem-router[each.key].self_link
}

################################################################################
#                               NCC Configuration                              #
################################################################################

resource "google_network_connectivity_hub" "ncc-hub" {
  name    = "ncc-hub"
  project = module.project.project_id
}

resource "google_network_connectivity_spoke" "spoke" {
  for_each = var.regions_config["hub"]
  name     = "spoke-${each.key}"
  location = each.key
  hub      = google_network_connectivity_hub.ncc-hub.id
  project  = module.project.project_id
  linked_router_appliance_instances {
    instances {
      virtual_machine = module.hub-router[each.key].instance.self_link
      ip_address      = google_compute_address.ra-hub[each.key].address
    }
    site_to_site_data_transfer = false
  }
}

# Google provider doesn't support to add interfaces to a Cloud Router from a
# subnetwork, needed for creating a RA spoke in NCC. Using 'gcloud' for now.
resource "google_compute_router" "cloud-router-ncc" {
  for_each = var.regions_config["hub"]
  name     = "hub-cr-ncc-${each.key}"
  network  = module.vpc["hub"].self_link
  region   = each.key
  project  = module.project.project_id
}

module "cloud-router-ncc-if-1" {
  for_each                 = var.regions_config["hub"]
  source                   = "terraform-google-modules/gcloud/google"
  version                  = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-interface hub-cr-ncc-${each.key} --project ${module.project.project_id}",
    "--interface-name=hub-router-1 --subnetwork=hub-${each.key}-0",
    "--ip-address=${google_compute_address.cr-hub-1[each.key].address}",
    "--region=${each.key}"
  ])
  destroy_cmd_body  = "version" # do nothing
  module_depends_on = [google_compute_router.cloud-router-ncc]
}

module "cloud-router-ncc-if-2" {
  for_each                 = var.regions_config["hub"]
  source                   = "terraform-google-modules/gcloud/google"
  version                  = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-interface hub-cr-ncc-${each.key} --project ${module.project.project_id}",
    "--interface-name=hub-router-2 --subnetwork=hub-${each.key}-0",
    "--redundant-interface=hub-router-1 --ip-address=${google_compute_address.cr-hub-2[each.key].address}",
    "--region=${each.key}"
  ])
  destroy_cmd_body  = "version" # do nothing
  module_depends_on = [module.cloud-router-ncc-if-1]
}

module "cloud-router-ncc-bgp-1" {
  for_each                 = var.regions_config["hub"]
  source                   = "terraform-google-modules/gcloud/google"
  version                  = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-bgp-peer hub-cr-ncc-${each.key} --project ${module.project.project_id}",
    "--peer-name=hub-router-1 --interface=hub-router-1 --peer-asn=${var.gcp-asn-ra}",
    "--peer-ip-address=${google_compute_address.ra-hub[each.key].address}",
    "--instance=${module.hub-router[each.key].instance.name} --instance-zone=${each.key}-b",
    "--advertisement-mode=CUSTOM --set-advertisement-ranges=10.0.0.0/8",
    "--region=${each.key}"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers remove-bgp-peer hub-cr-ncc-${each.key} --project ${module.project.project_id}",
    "--peer-name=hub-router-1 --region=${each.key}"
  ])
  module_depends_on = [module.cloud-router-ncc-if-2]
}

module "cloud-router-ncc-bgp-2" {
  for_each                 = var.regions_config["hub"]
  source                   = "terraform-google-modules/gcloud/google"
  version                  = "3.1.0"
  service_account_key_file = "ncc-hub-project-f05272af14bb.json"
  create_cmd_body = join(" ", [
    "compute routers add-bgp-peer hub-cr-ncc-${each.key} --project ${module.project.project_id}",
    "--peer-name=hub-router-2 --interface=hub-router-2 --peer-asn=${var.gcp-asn-ra}",
    "--peer-ip-address=${google_compute_address.ra-hub[each.key].address}",
    "--instance=${module.hub-router[each.key].instance.name} --instance-zone=${each.key}-b",
    "--advertisement-mode=CUSTOM --set-advertisement-ranges=10.0.0.0/8",
    "--region=${each.key}"
  ])
  destroy_cmd_body = join(" ", [
    "compute routers remove-bgp-peer hub-cr-ncc-${each.key} --project ${module.project.project_id}",
    "--peer-name=hub-router-2 --region=${each.key}"
  ])
  module_depends_on = [module.cloud-router-ncc-bgp-1]
}

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
  # Wait for IP assignment for RAs in the hub is done to not 'steal' the IPs.
  depends_on = [google_compute_address.ra-hub]
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

module "vm-dev" {
  for_each   = var.regions_config["dev"]
  source     = "../../../modules/compute-vm"
  project_id = module.project.project_id
  zone       = "${each.key}-b"
  name       = "dev-${each.key}"
  network_interfaces = [{
    network    = module.vpc["dev"].self_link
    subnetwork = module.vpc["dev"].subnet_self_links["${each.key}/dev-${each.key}-0"]
    nat        = false
    addresses  = null
  }]
  service_account        = module.service-account-gce.email
  service_account_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  tags                   = ["ssh"]
}

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
  # Wait for IP assignment for RAs in onprem is done to not 'steal' the IPs.
  depends_on = [google_compute_address.ra-onprem]
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

