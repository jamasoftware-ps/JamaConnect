#!/usr/bin/env bash
#### Copyright © 2020 Jama Software
#### All Rights Reserved.

#set -o errexit
set -o pipefail
#set -o xtrace

#### Variables
replicatedVersion='2.42.5'
replicatedUiPort='8800'
dockerInstallUrl='https://get.docker.com'
export VERSION='18.09.2'        ## Docker version validated with Replicated and Jama Connect; used by Docker installer
dockerOptionFile='/etc/docker/daemon.json'
replicatedInstallUrl='https://get.replicated.com/docker?replicated_tag='
logFile='install.log'

## Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

#### Run as root or with sudo rights
if [[ $EUID > 0 ]]; then
    echo "Please run as root/sudo"
    exit 1
fi

#### Ensure we have access to the domains used by the installation script
## Domain list: https://help.replicated.com/community/t/customer-firewalls/55
## Test access to each domain, adding inaccessible domains to an array named noAccess
echo -e "${YELLOW}Testing network access...${NC}"
declare -a domains=(
'https://registry.replicated.com' 
'https://registry-data.replicated.com' 
'https://quay.io' 
'https://index.docker.io' 
'https://docker.io' 
'https://registry-1.docker.io' 
'https://api.replicated.com' 
'https://get.replicated.com')
declare -a noAccess=()
for domain in "${domains[@]}"
do
    #echo "curl ${domain}" > /dev/null 2>&1 || noAccess+=("${domain}")
    curl -s ${domain} > /dev/null
    #echo "${domain} exit code = $?"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}SUCCESS${NC}: ${domain}"
    else
	noAccess+=("${domain}")
    fi
done
## Printing list of domains that are inaccessible 
if [ ! -z ${noAccess} ]; then
    echo -e "\nPlease resolve network access to the domain(s) and try again..." | tee -a ${logFile}
    for domain in ${noAccess[@]}
    do
        echo -e "${RED}FAILED${NC}: ${domain}" | tee -a ${logFile}
    done
    exit 1
fi

#### Elasticsearch memory setting enforcement
## Ensure ES memory setting exists in /etc/sysctl.conf
grep 'vm.max_map_count.*262144' /etc/sysctl.conf > /dev/null 2>&1
if [ $? -ne "0" ]; then
    echo "vm.max_map_count = 262144" >> /etc/sysctl.conf | tee -a ${logFile}
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR${NC}: Failed to execute 'echo "vm.max_map_count = 262144" >> /etc/sysctl.conf'" | tee -a ${logFile}
        exit 1
    fi
fi
## Ensure ES memory setting is loaded in memory
sysctl --all | grep 'vm.max_map_count = 262144' > /dev/null 2>&1 | tee -a ${logFile}
if [ $? -ne "0" ]; then
    sysctl -w vm.max_map_count=262144
    if [ $? -ne 0 ]; then
        echo -e "${RED}ERROR${NC}: Failed to execute 'sysctl -w vm.max_map_count=262144'" | tee -a ${logFile}
        exit 1
    fi
fi

#### Clear the screen, removing the stdout from the ES memory grep above
clear

#### Docker installation
## Official Docker-CE installation scriph
if [ ! $(command -v docker) ]; then
    curl ${dockerInstallUrl} > /dev/null 2>&1
    if [ $? -eq 0 ]; then
	curl -fsSL ${dockerInstallUrl} | sh | tee -a ${logFile}
        if [ $? -ne 0 ]; then
            echo "${RED}ERROR${NC}: Something went wrong installing docker-ce-${VERSION}" | tee -a ${logFile}
            exit 1
        fi
    else
        echo "$RED}ERROR${NC}: Access to ${dockerInstallUrl} is not accessible from this server..." | tee -a ${logFile}
	exit 1 
    fi
fi

#### Get the docker0 bridge IP address - Used for the "private-address" during the installation of Replicated
if [ $(command -v ip) ]; then
    docker0Ip=$(ip addr show docker0 | grep 'inet ' | awk '{print $2}' | awk -F '/' '{print $1}')
elif [ $(command -v ifconfig) ]; then
    docker0Ip=$(ifconfig docker0 | grep 'inet ' | awk '{print $2}')
elif [ -f ${dockerOptionFile} ]; then
    docker0Ip=$(grep bip ${dockerOptionFile} | awk -F '"' '{print $4}' | awk -F '/' '{print $1}')
else
    docker0Ip=$(docker network inspect bridge | grep -A 15 '"Name": "bridge",' | grep Gateway | awk -F '"' '{print $4}')
fi
## Exit if we cannot get the docker0 interface IP address
if [ -z ${docker0Ip} ]; then
    echo "${RED}ERROR${NC}: Unable to determine the docker0 interface IP address" | tee -a ${logFile}
    exit 1
fi

#### Get the primary interface IP address - Used for the "public-address" during installation of Replicated
publicIp=
while IFS=$': \t' read -a line ;do
    [ -z "${line%inet}" ] && ip=${line[${#line[1]}>4?1:2]} &&
        [ "${ip#127.0.0.1}" ] && publicIp=$ip
  done< <(LANG=C /sbin/ifconfig)
## Exit if we cannot get the routable, primary interface IP address
if [ -z ${publicIp} ]; then
    echo "${RED}ERROR${NC}: Unable to determine the routable, primary interface IP address" | tee -a ${logFile}
    exit 1
fi

#### Replicated installation
echo -e "\n\n${YELLOW}Installing the Replicated Admin Console...${NC}"
curl -sSL "${replicatedInstallUrl}${replicatedVersion}" | bash -s \
        private-address="${docker0Ip}" \
        public-address="${publicIp}" \
        tags="jamacore,elasticsearch" \
        ui-bind-port="${replicatedUiPort}" \
        no-auto \
        | tee -a ${logFile}

