locals {
    owner_email = "zhamilton@confluent.io"
    aws_region = "ca-central-1"
}
resource "random_id" "net_seg" {
    byte_length = 4
}
resource "random_id" "aggregator" {
    byte_length = 4
}
# Capture the current public ip of the machine running this
data "http" "myip" {
    url = "http://ipv4.icanhazip.com"
}
# Gather all the service ips from aws
data "http" "ec2_instance_connect" {
    url = "https://ip-ranges.amazonaws.com/ip-ranges.json"
}
# Specifically get the ec2 instance connect service ip so it can be whitelisted
locals {
    ec2_instance_connect_ip = [ for e in jsondecode(data.http.ec2_instance_connect.response_body)["prefixes"] : e.ip_prefix if e.region == "${local.aws_region}" && e.service == "EC2_INSTANCE_CONNECT" ]
}
# Find instance ami and type
data "aws_ami" "amazon_linux" {
    owners = [ "amazon" ]
    most_recent = true
    filter {
        name = "name"
        values = [ "amzn2-ami-kernel-5.10-hvm-*" ]
    }
}
data "aws_ec2_instance_type" "collector" {
    instance_type = "t3.micro"
}
data "aws_ec2_instance_type" "replicator" {
    instance_type = "t3.medium"
}
data "aws_ec2_instance_type" "es" {
    instance_type = "t3.medium"
}