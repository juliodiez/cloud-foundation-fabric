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
  default = {
    hub = {
      europe-west1 = ["10.0.0.0/28", "10.0.0.16/28"]
      europe-west3 = ["10.0.0.32/28", "10.0.0.48/28"]
    }
    prod = {
      europe-west1 = ["10.0.1.0/24"]
      europe-west3 = ["10.0.2.0/24"]
    }
    # Uncomment if you want to add "dev" VPC spoke.
    dev = {
      europe-west1 = ["10.0.3.0/24"]
      europe-west3 = ["10.0.4.0/24"]
    }
    # This VPC simulates the onprem DC and we use only one region.
    onprem = {
      europe-west1 = ["10.128.0.0/24"]
    }
  }
}

/* variable "ip_ranges" {
  description = "IP CIDR ranges."
  type        = map(string)
  default = {
    hub     = "10.0.0.0/24"
    spoke-1 = "10.0.16.0/24"
    spoke-2 = "10.0.32.0/24"
    onprem  = "10.0.128.0/20"
  }
} */

/* variable "ip_secondary_ranges" {
  description = "Secondary IP CIDR ranges."
  type        = map(string)
  default = {
    spoke-2-pods     = "10.128.0.0/18"
    spoke-2-services = "172.16.0.0/24"
  }
} */

/* variable "prefix" {
  description = "Arbitrary string used to prefix resource names."
  type        = string
  default     = null
} */

/* variable "private_service_ranges" {
  description = "Private service IP CIDR ranges."
  type        = map(string)
  default = {
    spoke-2-cluster-1 = "192.168.0.0/28"
  }
} */

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

/* variable "region" {
  description = "VPC region."
  type        = string
  default     = "europe-west1"
} */
