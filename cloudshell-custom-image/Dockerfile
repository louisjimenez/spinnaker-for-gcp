FROM gcr.io/cloudshell-images/cloudshell:latest

ENV PROJECT_ID=$PROJECT_ID
ENV DEVSHELL_SERVER_BASE_URL=""
ENV ATTACHING_DISK=false

COPY entry.sh /entry.sh
WORKDIR /tmp

RUN git clone https://github.com/GoogleCloudPlatform/spinnaker-for-gcp.git
ENTRYPOINT ["/entry.sh"]
