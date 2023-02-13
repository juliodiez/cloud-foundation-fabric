/**
 * Copyright 2023 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

variable "image" {
  description = "Container image to deploy."
  type        = string
  default     = "us-docker.pkg.dev/cloudrun/container/hello"
}

variable "ingress_settings" {
  description = "Ingress traffic sources allowed to call the service."
  type        = string
  default     = "all"
}

variable "ip_ranges_host" {
  description = "IPs or IP ranges used by VPCs"
  type = object({
    subnet   = string
    psc_addr = string
  })
  default = {
    subnet   = "10.0.1.0/24"
    psc_addr = "10.0.0.100"
  }
}

variable "prj_host_create" {
  description = "Parameters for the creation of a host project."
  type = object({
    billing_account_id = string
    parent             = string
  })
  default = null
}

variable "prj_host_id" {
  description = "Host Project ID."
  type        = string
}

variable "region" {
  description = "Cloud region where resource will be deployed."
  type        = string
  default     = "europe-west1"
}

variable "run_svc_name" {
  description = "Cloud Run service name."
  type        = string
  default     = "hello"
}
