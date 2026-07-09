terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.0" }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      project = "homelab-demo"
      owner   = "jocelyn"
    }
  }
}

resource "aws_vpc" "demo" {
  cidr_block           = "10.42.0.0/16"
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.demo.id
  cidr_block              = "10.42.1.0/24"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "gw" { vpc_id = aws_vpc.demo.id }

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.demo.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "demo" {
  vpc_id = aws_vpc.demo.id
  ingress {
    description = "app"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "ssh — lock to your IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip_cidr]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.medium"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.demo.id]
  key_name               = var.key_name

  instance_market_options {
    market_type = "spot"
  }

  user_data = <<-CLOUDINIT
    #!/bin/bash
    curl -sfL https://get.k3s.io | sh -
    # deploy demo app the GitOps way: same manifest as the homelab
    kubectl apply -f https://raw.githubusercontent.com/YOUR-GH-USER/homelab-infra/main/kubernetes/demo-app/deploy.yaml
    # belt-and-braces cost guard: self-destruct after 2 hours
    shutdown -h +120
  CLOUDINIT
}

output "demo_url" { value = "http://${aws_instance.k3s.public_ip}" }
