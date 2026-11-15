#!/bin/sh
# Allow the webhook port of doco-cd (8081) only from the cluster nodes.
# Docker publishes the port with NAT, so a rule of ufw or INPUT does not see
# the traffic. The chain DOCKER-USER is the place that Docker keeps for it.
# The script removes its own rules first, so a second run changes nothing.
set -eu

PORT=8081
# The Talos nodes. A pod reaches the host with the address of its node.
NODES="10.30.50.20 10.30.50.21 10.30.50.22 10.30.50.33"
TAG="doco-cd-webhook"

# No interface match: a DROP that names an interface does nothing when the
# name is wrong, and the port would stay open.
match="-p tcp -m conntrack --ctorigdstport $PORT --ctdir ORIGINAL -m comment --comment $TAG"

# Delete every rule with the tag.
while rule=$(iptables -S DOCKER-USER | grep -m1 -- "--comment $TAG"); do
  # The rule has no quoted word, so word splitting is safe here.
  # shellcheck disable=SC2046
  iptables $(echo "$rule" | sed 's/^-A /-D /')
done

# Insert at the top: the DROP first, then each ACCEPT above it.
# shellcheck disable=SC2086
iptables -I DOCKER-USER 1 $match -j DROP
for node in $NODES; do
  # shellcheck disable=SC2086
  iptables -I DOCKER-USER 1 -s "$node" $match -j RETURN
done

# Stop with an error if the DROP is not in the chain. The port must not stay open.
iptables -S DOCKER-USER | grep -q -- "--comment $TAG -j DROP" || {
  echo "doco-cd-firewall: the DROP rule is missing" >&2
  exit 1
}
