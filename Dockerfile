FROM louislam/uptime-kuma:1

RUN apt update && \
    apt install -y python3 python3-pip && \
    pip3 install botocore 