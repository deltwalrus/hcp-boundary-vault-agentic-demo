FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    openssh-server \
    supervisor \
    sudo \
    python3 \
    python3-pip \
    curl \
    jq \
    net-tools \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Create the OS user the agent will log in as via Vault-signed SSH certificates.
# usermod -p '*' sets an unmatchable-but-unlocked password hash: useradd with
# no password leaves the account LOCKED in /etc/shadow, and OpenSSH refuses
# locked accounts outright regardless of auth method (cert included) — this
# is unrelated to PasswordAuthentication being off.
#
# NOPASSWD sudo for everything: this container's only inbound path is a
# Boundary-brokered SSH session with a 5-min Vault-signed cert -- the access
# control this demo showcases happens before the agent ever reaches a shell,
# not at the OS sudoers layer. Scoping sudoers to individual commands just
# makes the remediation step fragile against how the agent happens to phrase
# a command, for no real security benefit here.
RUN useradd -m -s /bin/bash ubuntu \
    && usermod -p '*' ubuntu \
    && echo "ubuntu ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers

# SSH: accept certificates signed by the Vault CA (key fetched at container start)
RUN mkdir -p /var/run/sshd
COPY sshd_config /etc/ssh/sshd_config

# Supervisor manages sshd + the demo web service
RUN mkdir -p /var/log/supervisor
COPY supervisord.conf /etc/supervisor/conf.d/demo.conf

# Demo web application
COPY requirements.txt /opt/demo-web-app/requirements.txt
RUN pip3 install --no-cache-dir -r /opt/demo-web-app/requirements.txt
COPY app.py /opt/demo-web-app/app.py

# Mock systemctl so the agent can use familiar commands
COPY systemctl-mock.sh /usr/local/bin/systemctl
RUN chmod +x /usr/local/bin/systemctl

# journalctl mock — tails the app log
COPY journalctl-mock.sh /usr/local/bin/journalctl
RUN chmod +x /usr/local/bin/journalctl

# Broken initial config — PORT=not-a-number causes the service to fail on start
RUN printf 'PORT=not-a-number\nAPP_ENV=production\nLOG_LEVEL=info\n' \
    > /etc/demo-web-app.env

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 22 8080

CMD ["/entrypoint.sh"]
