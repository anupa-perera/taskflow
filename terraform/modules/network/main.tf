data "aws_region" "current" {}

locals {
  # /16 + 8 bits = /24 subnets. Private subnets add 10 to the AZ's number so the two tiers are easy
  # to tell apart from an IP alone (10.0.0.x public, 10.0.10.x private).
  subnet_newbits        = 8
  private_netnum_offset = 10

  # keys() is sorted, so this is stable: the lexically first AZ hosts the single NAT gateway.
  nat_az = keys(var.availability_zones)[0]
}

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  # Required for RDS endpoints and interface endpoints to resolve inside the VPC.
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = var.name }
}

# The default security group allows all traffic between its members; nothing should use it, so it
# is managed with no rules.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = "${var.name}-default-unused" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = { Name = var.name }
}

# Public subnets hold only the ALB and the NAT gateway; nothing in them gets a public IP by default.
resource "aws_subnet" "public" {
  for_each = var.availability_zones

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, local.subnet_newbits, each.value)

  tags = {
    Name = "${var.name}-public-${each.key}"
    Tier = "public"
  }
}

# Private subnets hold the ECS hosts and RDS; they reach the internet only outbound, via the NAT.
resource "aws_subnet" "private" {
  for_each = var.availability_zones

  vpc_id            = aws_vpc.this.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, local.subnet_newbits, each.value + local.private_netnum_offset)

  tags = {
    Name = "${var.name}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name}-nat" }

  depends_on = [aws_internet_gateway.this]
}

# ponytail: one NAT gateway for all AZs; if its AZ fails, private subnets lose outbound access.
# Upgrade path: one NAT per AZ and one private route table per AZ (see README non-goals).
resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[local.nat_az].id

  tags = { Name = var.name }

  depends_on = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }

  tags = { Name = "${var.name}-private" }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

# ECR stores image layers in S3, so image pulls from the private subnets go through this free
# gateway endpoint instead of the NAT gateway, which charges per GB processed.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "${var.name}-s3" }
}
