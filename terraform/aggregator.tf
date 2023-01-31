resource "aws_vpc" "aggregator" {
    cidr_block = "10.0.0.0/16"
    tags = {
        Name = "aggregator-vpc"
        identifier = "${random_id.aggregator.hex}"
    }
}
resource "aws_internet_gateway" "aggregator" {
    vpc_id = aws_vpc.aggregator.id
    tags = {
        Name = "aggregator-vpc-igw"
        identifier = "${random_id.aggregator.hex}"
    }
}
resource "aws_subnet" "aggregator_public" {
    vpc_id = aws_vpc.aggregator.id 
    cidr_block = replace(aws_vpc.aggregator.cidr_block, "/.0.0/16/", ".${1}.0/24")
    tags = {
        Name = "aggregator-vpc-subnet"
        identifier = "${random_id.aggregator.hex}"
    }
}
resource "aws_route_table" "aggregator" {
    vpc_id = aws_vpc.aggregator.id
    tags = {
        Name = "aggregator-vpc-rt"
        identifier = "${random_id.aggregator.hex}"
    }
}
resource "aws_route_table_association" "aggregator" {
    route_table_id = aws_route_table.aggregator.id
    subnet_id = aws_subnet.aggregator_public.id
}
resource "aws_route" "aggregator_igw" {
    destination_cidr_block = "0.0.0.0/0"
    route_table_id = aws_route_table.aggregator.id 
    gateway_id = aws_internet_gateway.aggregator.id 
}
resource "aws_security_group" "es" {
    vpc_id = aws_vpc.aggregator.id
    name = "aggregator-es-sg"
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
        cidr_blocks = [ "${aws_vpc.aggregator.cidr_block}" ]
    }
    ingress {
        description = "Elasticsearch"
        from_port = 9200
        to_port = 9200
        protocol = "tcp"
        cidr_blocks = [ "0.0.0.0/0" ]
    }
    ingress {
        description = "Kibana"
        from_port = 5601
        to_port = 5601
        protocol = "tcp"
        cidr_blocks = [ "0.0.0.0/0" ]
    }
    tags = {
        Name = "aggregator-es-sg"
        identifier = "${random_id.aggregator.hex}"
    }
}
data "cloudinit_config" "aggregator_es" {
    gzip = false
    base64_encode = false
    part {
        content_type = "text/x-shellscript"
        filename = "start.sh"
        content = <<-EOF
            #!/bin/sh
            yum update -y
            yum install docker -y
            service docker start
            docker network create es
            docker run -d --name elasticsearch \
            -e discovery.type=single-node \
            -e cluster.name=es-cluster \
            -e node.name=es-node \
            -e discovery.seed_hosts=es-node \
            -p 9200:9200 \
            -p 9300:9300 \
            -h elasticseach \
            --network es \
            elasticsearch:7.10.1
            docker run -d --name kibana \
            -e ELASTICSEARCH_HOSTS=http://elasticseach:9200 \
            -p 5601:5601 \
            -h kibana \
            --network es \
            kibana:7.10.1
        EOF
    }
}
resource "aws_instance" "aggregator_es" {
    ami = data.aws_ami.amazon_linux.id
    instance_type = data.aws_ec2_instance_type.es.instance_type
    subnet_id = aws_subnet.aggregator_public.id
    vpc_security_group_ids = [aws_security_group.es.id]
    user_data = data.cloudinit_config.aggregator_es.rendered
    tags = {
        Name = "aggregator-es"
        identifier = "${random_id.aggregator.hex}"
    }
}
resource "aws_eip" "es_eip" {
    vpc = true
    instance = aws_instance.aggregator_es.id 
    tags = {
        Name = "aggregator-es-eip"
        identifier = "${random_id.aggregator.hex}"
    }
}
resource "confluent_environment" "aggregator" {
    display_name = "aggregator-${random_id.aggregator.hex}"
}
resource "confluent_kafka_cluster" "aggregator" {
    display_name = "aggregator" 
    availability = "SINGLE_ZONE" 
    cloud = "AWS"
    region = local.aws_region
    basic {}
    environment {
        id = confluent_environment.aggregator.id 
    }
}
resource "confluent_service_account" "aggregator" {
    display_name = "aggregator-sa-${random_id.aggregator.hex}"
}
resource "confluent_role_binding" "aggregator" {
    principal = "User:${confluent_service_account.aggregator.id}"
    role_name = "CloudClusterAdmin" 
    crn_pattern = confluent_kafka_cluster.aggregator.rbac_crn
}
resource "confluent_api_key" "aggregator" {
    display_name = "aggregator-key-${random_id.aggregator.hex}"
    owner {
        id = confluent_service_account.aggregator.id
        api_version = confluent_service_account.aggregator.api_version
        kind = confluent_service_account.aggregator.kind
    }
    managed_resource {
        id = confluent_kafka_cluster.aggregator.id
        api_version = confluent_kafka_cluster.aggregator.api_version
        kind = confluent_kafka_cluster.aggregator.kind
        environment {
            id = confluent_environment.aggregator.id
        }
    }
    depends_on = [
        confluent_role_binding.aggregator
    ]
}
resource "confluent_kafka_topic" "net_seg" {
    count = length(confluent_kafka_cluster.net_seg)
    kafka_cluster {
        id = confluent_kafka_cluster.aggregator.id
    }
    topic_name = "network-segment-${count.index}"
    rest_endpoint = confluent_kafka_cluster.aggregator.rest_endpoint
    credentials {
        key = confluent_api_key.aggregator.id
        secret = confluent_api_key.aggregator.secret
    }
}
resource "confluent_connector" "es_sink" {
    environment {
        id = confluent_environment.aggregator.id
    }
    kafka_cluster {
        id = confluent_kafka_cluster.aggregator.id 
    }
    config_sensitive = {}
    config_nonsensitive = {
        "topics" = "${join(",", [for topic in confluent_kafka_topic.net_seg.*.topic_name : format("%s", topic) ])}",
        "input.data.format" = "JSON",
        "connector.class" = "ElasticsearchSink",
        "name" = "ElasticsearchSinkConnector",
        "kafka.auth.mode" = "SERVICE_ACCOUNT",
        "kafka.service.account.id" = "${confluent_service_account.aggregator.id}",
        "connection.url" = "http://${aws_eip.es_eip.public_ip}:9200",
        "elastic.security.protocol" = "PLAINTEXT",
        "elastic.https.ssl.keystore.type" = "JKS",
        "elastic.https.ssl.truststore.type" = "JKS",
        "elastic.https.ssl.keymanager.algorithm" = "SunX509",
        "elastic.https.ssl.trustmanager.algorithm" = "PKIX",
        "elastic.https.ssl.endpoint.identification.algorithm" = "https",
        "key.ignore" = "true",
        "schema.ignore" = "true",
        "compact.map.entries" = "true",
        "write.method" = "INSERT",
        "behavior.on.null.values" = "ignore",
        "behavior.on.malformed.documents" = "fail",
        "drop.invalid.message" = "false",
        "batch.size" = "2000",
        "linger.ms" = "1000",
        "flush.timeout.ms" = "10000",
        "flush.synchronously" = "true",
        "connection.compression" = "false",
        "read.timeout.ms" = "15000",
        "tasks.max" = "1",
        "data.stream.type" = "none"
    }
    depends_on = [
        aws_instance.aggregator_es,
        aws_eip.es_eip,
        confluent_role_binding.aggregator
    ]
}