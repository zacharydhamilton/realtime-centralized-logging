docker run -d --name replicator \
-e CLUSTER_ID=network-segment-$SEGMENT_INDEX-replicator \
-e BOOTSTRAP_SERVER_NET_SEG=$BOOTSTRAP_SERVER_NET_SEG \
-e KAFKA_CLUSTER_KEY_NET_SEG=$KAFKA_CLUSTER_KEY_NET_SEG \
-e KAFKA_CLUSTER_SECRET_NET_SEG=$KAFKA_CLUSTER_SECRET_NET_SEG \
-e SEGMENT_INDEX=$SEGMENT_INDEX \
-e BOOTSTRAP_SERVER_AGGREGATOR=$BOOTSTRAP_SERVER_AGGREGATOR \
-e KAFKA_CLUSTER_KEY_AGGREGATOR=$KAFKA_CLUSTER_KEY_AGGREGATOR \
-e KAFKA_CLUSTER_SECRET_AGGREGATOR=$KAFKA_CLUSTER_SECRET_AGGREGATOR \
-v /mnt/replicator/config:/etc/replicator \
confluentinc/cp-enterprise-replicator-executable:7.3.1

docker run -d --name replicator \
-e CLUSTER_ID=network-segment-$SEGMENT_INDEX-replicator \
-v /mnt/replicator/config:/etc/replicator \
confluentinc/cp-enterprise-replicator-executable:7.3.1

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


{
  "name": "ElasticsearchSinkConnector",
  "config": {
    "topics": "network-segment-0,network-segment-1,network-segment-2",
    "input.data.format": "JSON",
    "connector.class": "ElasticsearchSink",
    "name": "ElasticsearchSinkConnector",
    "kafka.auth.mode": "SERVICE_ACCOUNT",
    "kafka.service.account.id": "sa-5qrx2z",
    "connection.url": "http://3.97.86.145:9200",
    "elastic.security.protocol": "PLAINTEXT",
    "elastic.https.ssl.keystore.type": "JKS",
    "elastic.https.ssl.truststore.type": "JKS",
    "elastic.https.ssl.keymanager.algorithm": "SunX509",
    "elastic.https.ssl.trustmanager.algorithm": "PKIX",
    "elastic.https.ssl.endpoint.identification.algorithm": "https",
    "key.ignore": "true",
    "schema.ignore": "true",
    "compact.map.entries": "true",
    "write.method": "INSERT",
    "behavior.on.null.values": "ignore",
    "behavior.on.malformed.documents": "fail",
    "drop.invalid.message": "false",
    "batch.size": "2000",
    "linger.ms": "1000",
    "flush.timeout.ms": "10000",
    "flush.synchronously": "true",
    "connection.compression": "false",
    "read.timeout.ms": "15000",
    "tasks.max": "1",
    "data.stream.type": "none"
  }
}