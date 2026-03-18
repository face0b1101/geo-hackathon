ARG ELASTIC_STACK_VERSION
FROM docker.elastic.co/logstash/logstash:${ELASTIC_STACK_VERSION}
RUN logstash-plugin install logstash-filter-http
