# Test image for wg-it: a "server" with sshd, sudo, ufw and wireguard-tools, but no systemd.
# systemctl is a stub (systemctl-stub.sh) that maps wg-quick@IFACE to `wg-quick up|down IFACE`.
FROM ubuntu:24.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends \
      openssh-server sudo ufw wireguard-tools iproute2 iputils-ping netcat-openbsd curl ca-certificates >/dev/null \
 && rm -rf /var/lib/apt/lists/* && mkdir -p /run/sshd /root/.ssh && chmod 700 /root/.ssh \
 && sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
COPY systemctl-stub.sh /usr/local/bin/systemctl
RUN chmod 755 /usr/local/bin/systemctl
CMD ["/usr/sbin/sshd", "-D", "-e"]
