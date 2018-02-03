# tc-gen
tc-gen is a wrapper around all the complexity of modern traffic shaping and
policing on linux. It tries to use best practices whenever possible while still
being generic and easy to use. The script is using HTB with fq_codel to do
the heavy lifting.

Run tc-gen without parameters to see more details.

## Examples of common use
Shape egress to 25 mbit/s

    tc-gen -i eth0 -u 25
Shape egress to 5 mbit/s and ingress to 10 mbit/s using IFB-interface

    tc-gen -i eth0 -u 5 -d 10 -f ifb0
Shape egress to 1500 kbit/s and police ingress to 20 mbit/s

    tc-gen -i eth0 -u 1500k -d 20M
Display current configuration

    tc-gen -i eth0
Remove configuration

    tc-gen -i eth0 -x

## /etc/network/interfaces examples
    # Simple DHCP WAN config
    allow-auto eth1
    iface eth1 inet dhcp
        up /usr/local/bin/tc-gen -i ${IFACE} -u 10 -d 100 -f ifb0

    # More advanced example with an additional tc filter exclude for
    # UDP-encapsulated IPsec ESP-traffic to avoid double counting IPsec data on
    # ingress
    allow-auto bond0.12
    iface bond0.12 inet dhcp
        up /usr/local/bin/tc-gen -i ${IFACE} -u 10 -d 100 -f ifb0

    # Add additional rules to the post-commands file (location can be overridden by -p)
    echo '${TC} filter add dev ${IF_NAME} parent ffff: protocol ip prio 1 u32 match ip protocol 17 0xff match ip dport 4500 0xffff action pass' >> /etc/tc-gen/post-commands.bond0.12

    # Example with egress shaping on gre-tunnel
    allow-auto gre2
    iface gre2 inet tunnel
        address 10.0.1.0
        netmask 255.255.255.254
        local 10.0.2.2
        endpoint 10.1.2.2
        mode gre
        mtu 1400
        up /usr/local/bin/tc-gen -i ${IFACE} -u 25
