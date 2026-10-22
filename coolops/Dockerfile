ARG BASE_IMAGE
FROM ${BASE_IMAGE}
RUN apt-get update && apt-get install -y --no-install-recommends openssh-server jq \
    && rm -rf /var/lib/apt/lists/* /etc/ssh/ssh_host_* \
    && mkdir -p /run/sshd /data/sftp /data/hostkeys
COPY entrypoint.sh /usr/local/sbin/coolops-sftp
COPY sshd_config /etc/ssh/sshd_config
RUN chmod 755 /usr/local/sbin/coolops-sftp
EXPOSE 22
ENTRYPOINT ["/usr/local/sbin/coolops-sftp"]
