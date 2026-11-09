# Dockerfile
FROM atmoz/sftp:latest

# Install jq for JSON parsing using apt (assuming Debian-based image)
USER root
RUN apt-get update && apt-get install -y jq

# Ensure we expose SFTP port 22
EXPOSE 22

# Set up environment variable for the configuration file location
ENV SFTP_CONFIG /data/config/sftp/sftp_config.json

# Copy the entrypoint script that will handle user creation
COPY entrypoint.sh /entrypoint.sh
COPY hostkeys.sh /usr/local/sbin/sftp-hostkeys
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# Each deployment owns its keys in the existing persistent config mount.
# Never bake a server identity into an image.
RUN rm -f /etc/ssh/ssh_host_* && chmod 755 /usr/local/sbin/sftp-hostkeys

ENTRYPOINT ["/entrypoint.sh"]

