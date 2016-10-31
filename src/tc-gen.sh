#!/bin/bash


TC=$(which tc)
ETHTOOL=$(which ethtool)
IP=$(which ip)
MODPROBE=$(which modprobe)


error_handler () {
    local SCRIPT_NAME="$0"
    local LINE="$1"
    local EXIT_CODE="$2"
    echo "${SCRIPT_NAME}: Error in line ${LINE} (exit code ${EXIT_CODE})"
    exit ${EXIT_CODE}
}

trap 'error_handler ${LINENO} $?' ERR INT TERM
set -o errtrace -o pipefail


print_usage () {
    cat << EOF
tc-gen.sh -i IF_NAME [OPTIONS]

    -i IF_NAME
        If this is the only option, the current filter, qdisc and class
        configuration on the interface is displayed.

OPTIONS
    -u UP_RATE_MBITS
    -d DOWN_RATE_MBITS
    -f IFB_IF_NAME
        If ingress shaping should be used instead of policing define a valid
        ifb interface. Normally ifb0 and ifb1 is available if nothing is
        configured beyond loading the ifb kernel module.
    -b BURST_SIZE
        Only used when ingress policing is used. For ingress shaping this is
        ignored.
    -c "<fwmark>:<rate>:<ceil>:<prio>,<fwmark2>:<rate2>:<ceil2>:<prio2>,..."
        Define extra leaf classes if you want to slice up and guarantee
        bandwith between different kinds of traffic using fw marks. The default
        class has a priority of 4. If this is not set all the bandwith is
        given to the default class which is sufficient for most use cases.
        These classes are only used for egress shaping.
        If ceil is not set it will default to UP_RATE_MBITS. If prio is not
        set, it will default to the same priority as the default class.

        Example:
            -c "107:50::,109:30:70:2"

        The example above creates a leaf class which get all egress traffic
        with fw mark 107, shaped to a rate of 50 mbit/s with no ceiling and
        priority, which means that it may use all the available bandwith if
        available in the root class and has the same priority as the default
        class. The next leaf class has a fw mark of 109, a rate of 30 mbit/s,
        a ceil of 70 mbit/s and a priority of 2.
    -x
        Clear all traffic control config on interface.

EXAMPLES OF COMMON USE
    Shape egress to 25 mbit/s
        tc-gen.sh -i eth0 -u 25

    Shape egress to 5 mbit/s and ingress to 10 mbit/s using IFB-interface
        tc-gen.sh -i eth0 -u 5 -d 10 -f ifb0

    Shape egress to 2 mbit/s and police ingress to 20 mbit/s
        tc-gen.sh -i eth0 -u 2 -d 20

    Display current configuration
        tc-gen.sh -i eth0

    Remove configuration
        tc-gen.sh -i eth0 -x

    Always use ingress shaping vs policing if you want the best results. An
    additional bonus is that GRO normally can be left on when not using
    policing with good results.

EGRESS TRAFFIC SHAPING
    UP_RATE_MBITS uses HTB and fq_codel to efficiently shape upload
    traffic.

INGRESS TRAFFIC SHAPING
    If DOWN_RATE_MBITS and IFB_IF_NAME is set, ingress traffic shaping using
    an IFB-interface, HTB and fq_codel, is used for incoming traffic.

INGRESS TRAFFIC POLICING
    BURST_SIZE is only used for ingress policing.
    Ingress policing is used if IFB_IF_NAME is not defined and DOWN_RATE_MBITS
    is set. A good starting point for the burst size is

        phy_line_rate_in_bps * burst_time_seconds / 8 = burst_size_in_bytes

    with a burst_time_seconds value of 0.005s, or 5ms.

    If BURST_SIZE is not set a default burst size of

        MTU * 10 = burst_size_in_bytes

    is used.

    Ingress policing is very unreliable unless generic receive offload is
    disabled for the interface. For bonds and VLAN interfaces you have to
    disable GRO for the actual physical NICs manually as the script does
    not know the interface names of those. Disabling GRO usually leads to a
    massive increase in CPU-usage for high bandwith and might not be an option
    in many systems.

EXCLUDE TRAFFIC FROM INGRESS FILTERING
    The catch all filter for ingress has a priority of 99. This means that it
    is possible to manually add lower priority filter rules e.g. to exclude
    traffic from rate limiting. This is typically used for IPsec ESP-packets
    as they are seen both in its encrypted and decrypted form on the ingress
    interface if the tunnels are terminated locally, resulting in double
    counting of the traffic.
EOF
}

get_htb_quantum () {
    # Takes input rate in mbit/s as parameter
    local RATE=$1
    local QUANTUM

    if [[ ${RATE} -lt 40 ]]; then
        QUANTUM=1514
    else
        QUANTUM=8000
    fi

    echo ${QUANTUM}
}

get_target () {
    # Takes input rate in mbit/s and mtu as parameter
    local RATE=$1
    local MTU=$2
    local KBYTES=$(( ${RATE} * 1000 / 8 ))
    local MS=$(( ${MTU} / ${KBYTES} ))
    local TARGET

    if [[ ${MS} -gt 5 ]]; then
        TARGET=$(( ${MS} + 1 ))
    else
        TARGET=5
    fi

    echo "${TARGET}.0ms"
}

get_fq_codel_quantum () {
    # Takes input rate in mbit/s as parameter
    local RATE=$1

    if [[ ${RATE} -lt 100 ]]; then
        echo "quantum 300"
    fi
}

get_mtu () {
    # Takes interface as parameter
    cat /sys/class/net/${1}/mtu
}

get_limit () {
    # Takes rate in mbit/s as parameter
    local RATE=$1
    local LIMIT

    if [[ ${RATE} -le 10 ]]; then
        LIMIT=600
    elif [[ ${RATE} -le 100 ]]; then
        LIMIT=800
    elif [[ ${RATE} -le 1000 ]]; then
        LIMIT=1200
    else
        LIMIT=10000
    fi

    echo ${LIMIT}
}

clear_all () {
    ${TC} qdisc del dev ${IF_NAME} root > /dev/null 2>&1 || true
    ${TC} qdisc del dev ${IF_NAME} ingress > /dev/null 2>&1 || true

    if [[ -n ${IFB_IF_NAME} ]]; then
        ${TC} qdisc del dev ${IFB_IF_NAME} root > /dev/null 2>&1 || true
    fi

    ${ETHTOOL} --offload ${IF_NAME} gro on tso on gso on
}

get_ifb_if () {
    local IF_NAME="$1"
    local REGEX="\(Egress Redirect to device ([a-zA-Z0-9]+)\)"

    if [[ $(${TC} -s -d filter show dev ${IF_NAME} parent ffff:) =~ $REGEX ]]
    then
        echo "${BASH_REMATCH[1]}"
    fi
}

print_config () {
    local IF_NAME="$1"

    echo -e "### INTERFACE: ${IF_NAME} ###\n"
    echo "=== Filters ==="
    ${TC} -s -d filter show dev ${IF_NAME}
    ${TC} -s -d filter show dev ${IF_NAME} parent ffff:

    echo -e "\n=== Classes ==="
    ${TC} -s -d class show dev ${IF_NAME}

    echo -e "\n=== Qdiscs ==="
    ${TC} -s -d qdisc show dev ${IF_NAME}
    echo ""

    local IFB=$(get_ifb_if ${IF_NAME})
    if [[ -n ${IFB} ]]; then
        print_config ${IFB}
    fi
}

apply_egress_shaping () {
    # tso and probably gso on the outgoing interface makes the shaping
    # inaccurate in my tests. It is not unusable with these on but the CPU
    # hit is minimal in my tests and it makes the shaping much more accurate.
    ${ETHTOOL} --offload ${IF_NAME} tso off gso off

    # Add root handle and set default leaf
    ${TC} qdisc add dev ${IF_NAME} root handle 1: htb default 99

    # Set the overall shaped rate of the interface
    ${TC} class add dev ${IF_NAME} parent 1: classid 1:1 htb rate ${UP_RATE}mbit

    local DEFAULT_RATE=${UP_RATE}
    local DEFAULT_PRIO=4

    if [[ -n ${CLASS_CONFIG} ]]; then
        local CLASSES=( $(echo "${CLASS_CONFIG}" | tr ',' ' ') )

        for CLASS in ${CLASSES[@]}; do
            local CONFIG=( $(echo "${CLASS}" | tr ':' ' ') )
            local FWMARK=${CONFIG[0]}
            local CLASS_RATE=${CONFIG[1]}
            local CEIL_RATE=${CONFIG[2]}
            local PRIO=${CONFIG[3]}
            local CLASS_ID=${FWMARK}

            if [[ -z ${CEIL_RATE} ]]; then
                CEIL_RATE=${UP_RATE}
            fi

            if [[ -z ${PRIO} ]]; then
                PRIO=${DEFAULT_PRIO}
            fi

            if [[ ${CEIL_RATE} -gt ${UP_RATE} ]]; then
                echo "ERROR: ceiling value should not be larger than total up rate"
                exit 1
            fi

            DEFAULT_RATE=$(( ${DEFAULT_RATE} - ${CLASS_RATE} ))

            if [[ ${DEFAULT_RATE} -le 0 ]]; then
                echo "ERROR: The aggregated guaranteed rate of the classes needs to be less than the total up rate to leave some room for the default class"
                exit 1
            fi

            ${TC} class add dev ${IF_NAME} parent 1:1 classid 1:${CLASS_ID} htb \
                rate ${CLASS_RATE}mbit ceil ${CEIL_RATE}mbit \
                prio ${PRIO} quantum $(get_htb_quantum ${CLASS_RATE})

            # Should the class rate or ceil be used for the calculations here??
            # Using ceil as this is probably the rate it is most often running
            # at.
            ${TC} qdisc replace dev ${IF_NAME} parent 1:${CLASS_ID} \
                handle ${CLASS_ID}: fq_codel \
                limit $(get_limit ${CEIL_RATE}) \
                target $(get_target ${CEIL_RATE} $(get_mtu ${IF_NAME})) \
                $(get_fq_codel_quantum ${CEIL_RATE}) \
                noecn

            ${TC} filter add dev ${IF_NAME} parent 1: protocol all \
                handle ${FWMARK} fw classid 1:${CLASS_ID}
        done
    fi

    # Create class for the default priority
    ${TC} class add dev ${IF_NAME} parent 1:1 classid 1:99 htb rate ${DEFAULT_RATE}mbit \
        ceil ${UP_RATE}mbit prio ${DEFAULT_PRIO} \
        quantum $(get_htb_quantum ${UP_RATE})

    # Set qdisc to fq_codel. Disabling ECN is recommended for egress
    ${TC} qdisc replace dev ${IF_NAME} parent 1:99 handle 99: fq_codel \
        limit $(get_limit ${UP_RATE}) \
        target $(get_target ${UP_RATE} $(get_mtu ${IF_NAME})) \
        $(get_fq_codel_quantum ${UP_RATE}) \
        noecn
}

apply_ingress_shaping () {
    # Create ingress on interface
    ${TC} qdisc add dev ${IF_NAME} handle ffff: ingress

    # Ensure the ifb interface is up
    ${MODPROBE} ifb
    ${IP} link set dev ${IFB_IF_NAME} up

    # Add root handle and set default leaf
    ${TC} qdisc add dev ${IFB_IF_NAME} root handle 1: htb default 99

    # Set the overall shaped rate of the interface
    ${TC} class add dev ${IFB_IF_NAME} parent 1: classid 1:1 htb rate ${DOWN_RATE}mbit

    # Create class for the default priority
    ${TC} class add dev ${IFB_IF_NAME} parent 1:1 classid 1:99 htb rate ${DOWN_RATE}mbit \
        ceil ${DOWN_RATE}mbit prio 0 \
        quantum $(get_htb_quantum ${DOWN_RATE})

    # Set qdisc to fq_codel. Enabling ECN is recommended for ingress
    ${TC} qdisc replace dev ${IFB_IF_NAME} parent 1:99 handle 99: fq_codel \
        limit $(get_limit ${DOWN_RATE}) \
        target $(get_target ${DOWN_RATE} $(get_mtu ${IF_NAME})) \
        $(get_fq_codel_quantum ${DOWN_RATE}) \
        ecn

    # Redirect all ingress traffic to IFB egress. Use prio 99 to make it
    # possible to insert filters earlier in the chain.
    ${TC} filter add dev ${IF_NAME} parent ffff: protocol all prio 99 u32 \
        match u32 0 0 \
        action mirred egress redirect dev ${IFB_IF_NAME}
}

apply_ingress_policing () {
    # Ingress policing is very unreliable unless generic receive offload is
    # disabled for the interface. Note that for bonds and VLAN interfaces
    # you have to disable gro for the actual physical NICs manually. This
    # greatly increases CPU-usage in most systems for higher bandwiths.
    ${ETHTOOL} --offload ${IF_NAME} gro off

    # Create ingress on interface
    ${TC} qdisc add dev ${IF_NAME} handle ffff: ingress

    local MTU=$(get_mtu ${IF_NAME})

    if [[ -z ${BURST_SIZE} ]]; then
        BURST_SIZE=$(( ${MTU} * 10 ))
    fi

    # Police all ingress traffic. Use prio 99 to make it possible to insert
    # filters earlier in the chain.
    ${TC} filter add dev ${IF_NAME} parent ffff: protocol all prio 99 u32 \
        match u32 0 0 \
        police rate ${DOWN_RATE}mbit \
        burst ${BURST_SIZE} \
        mtu ${MTU} drop flowid :1
}


# All rates should be given in mbit/s
while getopts ":i:u:d:b:f:q:c:x" OPT; do
    case $OPT in
        i)
            IF_NAME="${OPTARG}"
            ;;
        u)
            UP_RATE="${OPTARG}"
            ;;
        d)
            DOWN_RATE="${OPTARG}"
            ;;
        b)
            BURST_SIZE="${OPTARG}"
            ;;
        f)
            IFB_IF_NAME="${OPTARG}"
            ;;
        c)
            CLASS_CONFIG="${OPTARG}"
            ;;
        x)
            CLEAR_CONFIG=1
            ;;
        \?)
            print_usage
            exit 1
            ;;
    esac
done

if [[ -z ${IF_NAME} ]]; then
    print_usage
    exit 1
fi

if [[ -n ${CLEAR_CONFIG} ]]; then
    clear_all
    echo "Config cleared"
    exit 0
fi

if [[ -z ${UP_RATE} && -z ${DOWN_RATE} ]]; then
    print_config "${IF_NAME}"
    exit
fi

clear_all

if [[ -n ${UP_RATE} ]]; then
    apply_egress_shaping
fi

if [[ -n ${DOWN_RATE} ]]; then
    if [[ -n ${IFB_IF_NAME} ]]; then
        apply_ingress_shaping
    else
        apply_ingress_policing
    fi
fi


trap - ERR INT TERM
