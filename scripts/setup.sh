#!/bin/sh -e

DEBIAN_FRONTEND=noninteractive
DEBCONF_NONINTERACTIVE_SEEN=true

echo 'tzdata tzdata/Areas select Etc' | debconf-set-selections
echo 'tzdata tzdata/Zones/Etc select UTC' | debconf-set-selections
echo "locales locales/default_environment_locale select en_US.UTF-8" | debconf-set-selections
echo "locales locales/locales_to_be_generated multiselect en_US.UTF-8 UTF-8" | debconf-set-selections
rm -f "/etc/locale.gen"

apt update -qqy
apt upgrade -qqy
apt autoremove -qqy
apt install -qqy --no-install-recommends \
    bridge-utils \
    dnsmasq \
    iptables \
    libconfig9 \
    locales \
    modemmanager \
    netcat-openbsd \
    network-manager \
    openssh-server \
    qrtr-tools \
    rmtfs \
    sudo \
    systemd-timesyncd \
    tzdata \
    wireguard-tools \
    wpasupplicant \
    bash-completion \
    curl \
    ca-certificates \
    zram-tools \
    bc \
    netplan.io \
    mobile-broadband-provider-info

rm -f /etc/network/interfaces || true
mkdir -p /etc/netplan
cat <<'NPEOF' > /etc/netplan/01-br0.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    usb0:
      optional: true
    usb1:
      optional: true
  bridges:
    br0:
      interfaces: [usb0, usb1]
      addresses: [192.168.100.1/24]
      parameters:
        stp: false
      mtu: 1500
      dhcp4: false
      dhcp6: false
      routes: []
      nameservers:
        addresses: [127.0.0.1]
NPEOF

# Apply netplan at first boot via systemd service
cat <<'SRV' > /etc/systemd/system/netplan-apply.service
[Unit]
Description=Apply netplan configuration
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/netplan generate
ExecStart=/usr/sbin/netplan apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SRV

systemctl enable netplan-apply.service || true

# NAT + DNS redirect rules (will be added via rc.local if present)
cat <<'FW' > /usr/local/sbin/setup-fw.sh
#!/bin/sh
iptables -t nat -C POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -j MASQUERADE 2>/dev/null || \
iptables -t nat -A POSTROUTING -s 192.168.100.0/24 ! -d 192.168.100.0/24 -j MASQUERADE
for p in tcp udp; do
  iptables -t nat -C PREROUTING -i br0 -p $p --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
  iptables -t nat -A PREROUTING -i br0 -p $p --dport 53 -j REDIRECT --to-ports 53
done
ip6tables -t nat -C POSTROUTING -s dead:beef::/64 ! -d dead:beef::/64 -j MASQUERADE 2>/dev/null || \
ip6tables -t nat -A POSTROUTING -s dead:beef::/64 ! -d dead:beef::/64 -j MASQUERADE
for p in tcp udp; do
  ip6tables -t nat -C PREROUTING -i br0 -p $p --dport 53 -j REDIRECT --to-ports 53 2>/dev/null || \
  ip6tables -t nat -A PREROUTING -i br0 -p $p --dport 53 -j REDIRECT --to-ports 53
done
FW
chmod +x /usr/local/sbin/setup-fw.sh

# Hook into rc.local if present
if grep -q setup-fw.sh /etc/rc.local 2>/dev/null; then :; else
  if [ -f /etc/rc.local ]; then
    sed -i '/^exit 0/i /usr/local/sbin/setup-fw.sh' /etc/rc.local || true
  fi
fi

# Cleanup
apt clean
rm -rf /var/lib/apt/lists/*
rm /etc/machine-id
rm /var/lib/dbus/machine-id
rm /etc/ssh/ssh_host_*
find /var/log -type f -delete

passwd -dl root

# Add user
adduser --disabled-password --comment "" user
# Set password
passwd user << EOD
1
1
EOD
# Add user to sudo group
usermod -aG sudo user

cat <<EOF >>/etc/bash.bashrc

alias ls='ls --color=auto -lh'
alias ll='ls --color=auto -lhA'
alias l='ls --color=auto -l'
alias cl='clear'
alias ip='ip --color'
alias bridge='bridge -color'
alias free='free -h'
alias df='df -h'
alias du='du -hs'

EOF

cat <<EOF >> /etc/systemd/journald.conf
SystemMaxUse=300M
SystemKeepFree=1G
EOF

# install dnsproxy
bash /install_dnsproxy.sh

systemctl mask systemd-networkd-wait-online.service

# Prevent the accidental shutdown by power button
sed -i 's/^#HandlePowerKey=poweroff/HandlePowerKey=ignore/' /etc/systemd/logind.conf

# Enable IPv4 and IPv6 forwarding
if [ -f /etc/sysctl.conf ]; then
    sed -i -e 's/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' -e 's/^#net.ipv6.conf.all.forwarding=1/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf 2>/dev/null || true
    grep -q '^net.ipv4.ip_forward' /etc/sysctl.conf || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    grep -q '^net.ipv6.conf.all.forwarding' /etc/sysctl.conf || echo 'net.ipv6.conf.all.forwarding=1' >> /etc/sysctl.conf
else
    cat <<EOF2 > /etc/sysctl.conf
# Enable IPv4 forwarding
net.ipv4.ip_forward=1

# Enable IPv6 forwarding
net.ipv6.conf.all.forwarding=1
EOF2
fi
