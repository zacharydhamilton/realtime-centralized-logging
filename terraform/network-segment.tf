resource "aws_vpc" "net_seg" {
    count = 3
    cidr_block = "10.${100+count.index}.0.0/16"
    tags = {
        Name = "net-seg-vpc-${count.index}"
        identifier = "${random_id.net_seg.hex}"
    }
}
resource "aws_internet_gateway" "net_seg" {
    count = length(aws_vpc.net_seg)
    vpc_id = aws_vpc.net_seg[count.index].id
    tags = {
        Name = "net-seg-vpc-${count.index}-igw"
        identifier = "${random_id.net_seg.hex}"
    }
}
resource "aws_subnet" "net_seg_public" {
    count = length(aws_vpc.net_seg)
    vpc_id = aws_vpc.net_seg[count.index].id
    cidr_block = replace(aws_vpc.net_seg[count.index].cidr_block, "/.0.0/16/", ".${1+count.index}.0/24")
    tags = {
        Name = "net-seg-vpc-${count.index}-subnet"
        identifier = "${random_id.net_seg.hex}"
    }
}
resource "aws_route_table" "net_seg" {
    count = length(aws_vpc.net_seg)
    vpc_id = aws_vpc.net_seg[count.index].id
    tags = {
        Name = "net-seg-vpc-${count.index}-rt"
        identifier = "${random_id.net_seg.hex}"
    }
}
resource "aws_route_table_association" "net_seg" {
    count = length(aws_vpc.net_seg)
    route_table_id = aws_route_table.net_seg[count.index].id
    subnet_id = aws_subnet.net_seg_public[count.index].id
}
resource "aws_route" "net_seg_igw" {
    count = length(aws_vpc.net_seg)
    destination_cidr_block = "0.0.0.0/0"
    route_table_id = aws_route_table.net_seg[count.index].id 
    gateway_id = aws_internet_gateway.net_seg[count.index].id 
}
resource "aws_security_group" "collector" {
    count = length(aws_vpc.net_seg)
    vpc_id = aws_vpc.net_seg[count.index].id
    name = "net-seg-collector-${count.index}-sg"
    egress {
        description = "Allow all outbound"
        from_port = 0
        to_port = 0 
        protocol = -1
        cidr_blocks = [ "0.0.0.0/0" ]
    }
    ingress {
        description = "SSH"
        from_port = 22
        to_port = 22 
        protocol = "tcp" 
        cidr_blocks = [ "${local.ec2_instance_connect_ip[0]}", "${chomp(data.http.myip.response_body)}/32" ]
    }
    ingress {
        description = "PING"
        from_port = -1
        to_port = -1
        protocol = "icmp"
        cidr_blocks = [ "${aws_vpc.net_seg[count.index].cidr_block}" ]
    }
    tags = {
        Name = "net-seg-collector-${count.index}-sg"
        identifier = "${random_id.net_seg.hex}"
    }
}
data "cloudinit_config" "net_seg_collector" {
    count = length(confluent_kafka_cluster.net_seg)
    gzip = false
    base64_encode = false
    part {
        content_type = "text/x-shellscript"
        filename = "env.sh"
        content = <<-EOF
            #!/bin/sh
            echo BOOTSTRAP_SERVER=${substr(confluent_kafka_cluster.net_seg[count.index].bootstrap_endpoint,11,-1)} >> /etc/environment
            echo KAFKA_CLUSTER_KEY=${confluent_api_key.net_seg[count.index].id} >> /etc/environment
            echo KAFKA_CLUSTER_SECRET=${confluent_api_key.net_seg[count.index].secret} >> /etc/environment
            echo SEGMENT_INDEX=${count.index} >> /etc/environment
        EOF
    }
    part {
        content_type = "text/cloud-config"
        filename = "cloud-config.yaml"
        content = <<-EOF
            #cloud-config
            ${jsonencode({
                write_files = [
                    {
                        path = "/fluent-bit/etc/fluent-bit.conf"
                        permissions = "0644"
                        encoding = "b64"
                        content = filebase64("../configs/fluentbit/fluent-bit.conf")
                    },
                    {
                        path = "/fluent-bit/etc/input-syslog.conf"
                        permissions = "0644"
                        encoding = "b64"
                        content = filebase64("../configs/fluentbit/input-syslog.conf")
                    },
                    {
                        path = "/fluent-bit/etc/output-kafka.conf"
                        permissions = "0644"
                        encoding = "b64"
                        content = filebase64("../configs/fluentbit/output-kafka.conf")
                    },
                    {
                        path = "/fluent-bit/etc/parsers.conf"
                        permissions = "0644"
                        encoding = "b64"
                        content = filebase64("../configs/fluentbit/parsers.conf")
                    },
                ]
            })}
        EOF
    }
    part {
        content_type = "text/x-shellscript"
        filename = "start.sh"
        content = <<-EOF
            #!/bin/sh
            yum update -y
            yum install docker -y
            service docker start
            docker run -d --name fluentbit \
            -e BOOTSTRAP_SERVER=${substr(confluent_kafka_cluster.net_seg[count.index].bootstrap_endpoint,11,-1)} \
            -e KAFKA_CLUSTER_KEY=${confluent_api_key.net_seg[count.index].id} \
            -e KAFKA_CLUSTER_SECRET=${confluent_api_key.net_seg[count.index].secret} \
            -e SEGMENT_INDEX=${count.index} \
            -v /fluent-bit/etc/:/fluent-bit/etc/ \
            -v /var/log/messages:/var/log/messages \
            fluent/fluent-bit:2.0.8-debug
        EOF
    }
    # part {
    #     content_type = "text/x-shellscript"
    #     filename = "logger.sh"
    #     content = <<-EOF
    #         logger foobar
    #     EOF
    # }
}
resource "aws_instance" "net_seg_collector" {
    count = length(aws_vpc.net_seg)
    ami = data.aws_ami.amazon_linux.id
    instance_type = data.aws_ec2_instance_type.collector.instance_type
    subnet_id = aws_subnet.net_seg_public[count.index].id
    associate_public_ip_address = true
    vpc_security_group_ids = [aws_security_group.collector[count.index].id]
    user_data = data.cloudinit_config.net_seg_collector[count.index].rendered
    tags = {
        Name = "net-seg-${count.index}-collector"
        identifier = "${random_id.net_seg.hex}"
    }
}
data "cloudinit_config" "net_seg_replicator" {
    count = length(confluent_kafka_cluster.net_seg)
    gzip = false
    base64_encode = false
    part {
        content_type = "text/x-shellscript"
        filename = "env.sh"
        content = <<-EOF
            #!/bin/sh
            echo BOOTSTRAP_SERVER_NET_SEG=${substr(confluent_kafka_cluster.net_seg[count.index].bootstrap_endpoint,11,-1)} >> /etc/environment
            echo KAFKA_CLUSTER_KEY_NET_SEG=${confluent_api_key.net_seg[count.index].id} >> /etc/environment
            echo KAFKA_CLUSTER_SECRET_NET_SEG=${confluent_api_key.net_seg[count.index].secret} >> /etc/environment
            echo SEGMENT_INDEX=${count.index} >> /etc/environment
            echo BOOTSTRAP_SERVER_AGGREGATOR=${substr(confluent_kafka_cluster.aggregator.bootstrap_endpoint,11,-1)} >> /etc/environment
            echo KAFKA_CLUSTER_KEY_AGGREGATOR=${confluent_api_key.aggregator.id} >> /etc/environment
            echo KAFKA_CLUSTER_SECRET_AGGREGATOR=${confluent_api_key.aggregator.secret} >> /etc/environment
        EOF
    }
    part {
        content_type = "text/x-shellscript"
        filename = "configs.sh"
        content = <<-EOF
            #!/bin/sh
            chmod a+w -R /mnt/replicator/config
        EOF
    }
    part {
        content_type = "text/cloud-config"
        filename = "cloud-config.yaml"
        content = <<-EOF
            #cloud-config
            ${jsonencode({
                write_files = [
                    {
                        path = "/mnt/replicator/config/consumer.properties"
                        permissions = "0644"
                        content = <<-EOF
                            bootstrap.servers=${substr(confluent_kafka_cluster.net_seg[count.index].bootstrap_endpoint,11,-1)}
                            security.protocol=SASL_SSL
                            sasl.mechanism=PLAIN
                            sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="${confluent_api_key.net_seg[count.index].id}\" password=\"${confluent_api_key.net_seg[count.index].secret}\";
                        EOF
                    },
                    {
                        path = "/mnt/replicator/config/producer.properties"
                        permissions = "0644"
                        content = <<-EOF
                            bootstrap.servers=${substr(confluent_kafka_cluster.aggregator.bootstrap_endpoint,11,-1)}
                            security.protocol=SASL_SSL
                            sasl.mechanism=PLAIN
                            sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"${confluent_api_key.aggregator.id}\" password=\"${confluent_api_key.aggregator.secret}\";
                        EOF
                    },
                    {
                        path = "/mnt/replicator/config/replication.properties"
                        permissions = "0644"
                        content = <<-EOF
                            topic.regex=^network-segment-.*$
                            header.converter=io.confluent.connect.replicator.util.ByteArrayConverter
                            key.converter=io.confluent.connect.replicator.util.ByteArrayConverter
                            value.converter=io.confluent.connect.replicator.util.ByteArrayConverter
                        EOF
                    }
                ]
            })}
        EOF
    }
    part {
        content_type = "text/x-shellscript"
        filename = "start.sh"
        content = <<-EOF
            #!/bin/sh
            yum update -y
            yum install docker -y
            service docker start
            docker run -d --name replicator \
            -e CLUSTER_ID=network-segment-${count.index}-replicator \
            -v /mnt/replicator/config:/etc/replicator \
            confluentinc/cp-enterprise-replicator-executable:7.3.1
        EOF
    }
}
resource "aws_instance" "net_seg_replicator" {
    count = length(aws_vpc.net_seg)
    ami = data.aws_ami.amazon_linux.id
    instance_type = data.aws_ec2_instance_type.replicator.instance_type
    subnet_id = aws_subnet.net_seg_public[count.index].id
    associate_public_ip_address = true
    vpc_security_group_ids = [aws_security_group.collector[count.index].id]
    user_data = data.cloudinit_config.net_seg_replicator[count.index].rendered
    tags = {
        Name = "net-seg-${count.index}-replicator"
        identifier = "${random_id.net_seg.hex}"
    }
}


# Creat confluent resources for each net seg
resource "confluent_environment" "net_seg" {
    display_name = "net-seg-${random_id.net_seg.hex}"
}
resource "confluent_kafka_cluster" "net_seg" {
    count = length(aws_vpc.net_seg)
    display_name = "net-seg-${count.index}"
    availability = "SINGLE_ZONE"
    cloud = "AWS"
    region = local.aws_region
    basic {} 
    environment {
        id = confluent_environment.net_seg.id
    }
}
resource "confluent_service_account" "net_seg" {
    display_name = "net-seg-sa-${random_id.net_seg.hex}"
}
resource "confluent_role_binding" "net_seg" {
    count = length(confluent_kafka_cluster.net_seg)
    principal = "User:${confluent_service_account.net_seg.id}"
    role_name = "CloudClusterAdmin"
    crn_pattern = confluent_kafka_cluster.net_seg[count.index].rbac_crn
}
resource "confluent_api_key" "net_seg" {
    count = length(confluent_kafka_cluster.net_seg)
    display_name = "net-seg-key-${random_id.net_seg.hex}"
    owner {
        id = confluent_service_account.net_seg.id
        api_version = confluent_service_account.net_seg.api_version
        kind = confluent_service_account.net_seg.kind
    }
    managed_resource {
        id = confluent_kafka_cluster.net_seg[count.index].id
        api_version = confluent_kafka_cluster.net_seg[count.index].api_version
        kind = confluent_kafka_cluster.net_seg[count.index].kind
        environment {
            id = confluent_environment.net_seg.id
        }
    }
    depends_on = [
        confluent_role_binding.net_seg
    ]
}
resource "confluent_kafka_topic" "logs" {
    count = length(confluent_kafka_cluster.net_seg)
    kafka_cluster {
        id = confluent_kafka_cluster.net_seg[count.index].id
    }
    topic_name = "network-segment-${count.index}"
    rest_endpoint = confluent_kafka_cluster.net_seg[count.index].rest_endpoint
    credentials {
        key = confluent_api_key.net_seg[count.index].id
        secret = confluent_api_key.net_seg[count.index].secret
    }
}