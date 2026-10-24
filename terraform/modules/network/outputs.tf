output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "IPv4 range of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Subnets for internet-facing resources (the ALB), one per AZ, ordered by AZ name."
  value       = [for az in keys(var.availability_zones) : aws_subnet.public[az].id]
}

output "private_subnet_ids" {
  description = "Subnets for ECS hosts, tasks and RDS, one per AZ, ordered by AZ name."
  value       = [for az in keys(var.availability_zones) : aws_subnet.private[az].id]
}

output "nat_public_ip" {
  description = "Public source IP of private-subnet traffic routed through the NAT gateway."
  value       = aws_eip.nat.public_ip
}
