FROM fluent/fluentd:v1.19.3-debian-2.4@sha256:57d670d33bb9fd420dce95cc8930eae9ab027b34097860fe295d33edb5ecae33
USER root
ADD --checksum=sha256:a9fb5177bbe391da4fb1de434659125e5d39010b67340953742d68d9fddbf86c https://rubygems.org/downloads/fluent-plugin-grafana-loki-1.3.0.gem /tmp/loki-plugin.gem
RUN gem install /tmp/loki-plugin.gem --local --no-document
USER fluent
