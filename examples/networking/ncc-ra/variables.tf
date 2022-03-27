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

variable "regions_config" {
  description = "VPCs and their regions and CIDR ranges."
  type        = map(map(list(string)))
  # For convenience it is assumed block 10/8 is for GCP and 192.168/16 for onprem.
  default = {
    hub = {
      europe-west1 = ["10.0.0.0/26"]
      europe-west3 = ["10.0.0.64/26"]
    }
    prod = {
      europe-west1 = ["10.0.1.0/24", "10.0.2.0/24"]
      europe-west3 = ["10.0.3.0/24", "10.0.4.0/24"]
    }
    dev = {
      europe-west1 = ["10.0.5.0/24", "10.0.6.0/24"]
      europe-west3 = ["10.0.7.0/24", "10.0.8.0/24"]
    }
    # This VPC simulates the onprem DC and we use only one region.
    onprem = {
      europe-west1 = ["192.168.0.0/24"]
    }
  }
}

variable "bgp_network" {
  description = "Use a /30 CIDR from the 169.254.0.0/16 block for BGP sessions."
  type        = string
  default     = "169.254.0.0/30"
}

variable "gcp-asn-ra" {
  description = "ASN for RAs in GCP."
  type        = string
  default     = "65000"
}

variable "gcp-asn-cr" {
  description = "ASN for CRs in GCP."
  type        = string
  default     = "65001"
}

variable "onprem-asn" {
  description = "ASN for RAs in onprem."
  type        = string
  default     = "65010"
}

variable "project_create" {
  description = "Set to non null if project needs to be created."
  type = object({
    billing_account = string
    oslogin         = bool
    parent          = string
  })
  default = null
  validation {
    condition = (
      var.project_create == null
      ? true
      : can(regex("(organizations|folders)/[0-9]+", var.project_create.parent))
    )
    error_message = "Project parent must be of the form folders/folder_id or organizations/organization_id."
  }
}

variable "project_id" {
  description = "Project id used for all resources."
  type        = string
}
