variable "region" {
  type    = string
  default = "ap-east-1" # Hong Kong
}

variable "key_name" {
  type = string
}

variable "my_ip_cidr" {
  type        = string
  description = "Your IP for SSH, e.g. 1.2.3.4/32"
}
