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
RUN sed -i 's/\r$//' /entrypoint.sh && chmod +x /entrypoint.sh

# Generate SSH host keys if they don't already exist
RUN mkdir -p /etc/ssh && \
    ssh-keygen -A

ENTRYPOINT ["/entrypoint.sh"]

