variable "region" {
  type    = string
  default = "us-east-1"
}

variable "floci_endpoint" {
  description = "Endpoint do Floci."
  type        = string
  default     = "http://localhost:4566"
}
