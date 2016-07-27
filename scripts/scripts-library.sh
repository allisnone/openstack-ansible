#!/usr/bin/env bash

# Copyright 2014, Rackspace US, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.


## Vars ----------------------------------------------------------------------
LINE='----------------------------------------------------------------------'
MAX_RETRIES=${MAX_RETRIES:-5}
REPORT_DATA=${REPORT_DATA:-""}
ANSIBLE_PARAMETERS=${ANSIBLE_PARAMETERS:-" -e 'gather_facts=False' "}
STARTTIME="${STARTTIME:-$(date +%s)}"
PIP_INSTALL_OPTIONS=${PIP_INSTALL_OPTIONS:-'pip==8.1.2 setuptools==25.1.1 wheel==0.29.0 '}

# The default SSHD configuration has MaxSessions = 10. If a deployer changes
#  their SSHD config, then the ANSIBLE_FORKS may be set to a higher number. We
#  set the value to 10 or the number of CPU's, whichever is less. This is to
#  balance between performance gains from the higher number, and CPU
#  consumption. If ANSIBLE_FORKS is already set to a value, then we leave it
#  alone.
#  ref: https://bugs.launchpad.net/openstack-ansible/+bug/1479812
if [ -z "${ANSIBLE_FORKS:-}" ]; then
  CPU_NUM=$(grep -c ^processor /proc/cpuinfo)
  if [ ${CPU_NUM} -lt "10" ]; then
    ANSIBLE_FORKS=${CPU_NUM}
  else
    ANSIBLE_FORKS=10
  fi
fi


## Functions -----------------------------------------------------------------
# Determine the distribution we are running on, so that we can configure it
# appropriately.
function determine_distro {
    source /etc/os-release 2>/dev/null
    export DISTRO_ID="${ID}"
    export DISTRO_NAME="${NAME}"
    export DISTRO_VERSION_ID="${VERSION_ID}"
}

# Used to retry a process that may fail due to random issues.
function successerator {
  set +e
  # Get the time that the method was started.
  OP_START_TIME=$(date +%s)
  # Set the initial return value to failure.
  false
  for ((RETRY=0; $? != 0 && RETRY < MAX_RETRIES; RETRY++)); do
    if [ ${RETRY} -gt 1 ];then
      $@ -vvvv
    else
      $@
    fi
  done
  # If max retires were hit, fail.
  if [ $? -ne 0 ] && [ ${RETRY} -eq ${MAX_RETRIES} ];then
    echo -e "\nHit maximum number of retries, giving up...\n"
    exit_fail
  fi
  # Print the time that the method completed.
  OP_TOTAL_SECONDS="$(( $(date +%s) - OP_START_TIME ))"
  REPORT_OUTPUT="${OP_TOTAL_SECONDS} seconds"
  REPORT_DATA+="- Operation: [ $@ ]\t${REPORT_OUTPUT}\tNumber of Attempts [ ${RETRY} ]\n"
  echo -e "Run Time = ${REPORT_OUTPUT}"
  set -e
}

function install_bits {
  # Use the successerator to run openstack-ansible
  successerator openstack-ansible ${ANSIBLE_PARAMETERS} $@
}

function ssh_key_create {
  # Ensure that the ssh key exists and is an authorized_key
  key_path="${HOME}/.ssh"
  key_file="${key_path}/id_rsa"

  # Ensure that the .ssh directory exists and has the right mode
  if [ ! -d ${key_path} ]; then
    mkdir -p ${key_path}
    chmod 700 ${key_path}
  fi
  if [ ! -f "${key_file}" -a ! -f "${key_file}.pub" ]; then
    rm -f ${key_file}*
    ssh-keygen -t rsa -f ${key_file} -N ''
  fi

  # Ensure that the public key is included in the authorized_keys
  # for the default root directory and the current home directory
  key_content=$(cat "${key_file}.pub")
  if ! grep -q "${key_content}" ${key_path}/authorized_keys; then
    echo "${key_content}" | tee -a ${key_path}/authorized_keys
  fi
}

function exit_state {
  set +x
  TOTALSECONDS="$(( $(date +%s) - STARTTIME ))"
  info_block "Run Time = ${TOTALSECONDS} seconds || $((TOTALSECONDS / 60)) minutes"
  if [ "${1}" == 0 ];then
    info_block "Status: Success"
  else
    info_block "Status: Failure"
  fi
  exit ${1}
}

function exit_success {
  set +x
  [[ "${OSA_GATE_JOB:-false}" = true ]] && gate_job_exit_tasks
  exit_state 0
}

function exit_fail {
  set +x
  log_instance_info
  info_block "Error Info - $@"
  [[ "${OSA_GATE_JOB:-false}" = true ]] && gate_job_exit_tasks
  exit_state 1
}

function gate_job_exit_tasks {
  [[ -d "/openstack/log" ]] && chmod -R 0777 /openstack/log
}

function print_info {
  PROC_NAME="- [ $@ ] -"
  printf "\n%s%s\n" "$PROC_NAME" "${LINE:${#PROC_NAME}}"
}

function info_block {
  echo "${LINE}"
  print_info "$@"
  echo "${LINE}"
}

function log_instance_info {
  set +x
  # Get host information post initial setup and reset verbosity
  if [ ! -d "/openstack/log/instance-info" ];then
    mkdir -p "/openstack/log/instance-info"
  fi
  get_instance_info
  set -x
}

function get_repos_info {
  for i in /etc/apt/sources.list /etc/apt/sources.list.d/* /etc/yum.conf /etc/yum.repos.d/*; do
    if [ -f "${i}" ]; then
      echo -e "\n$i"
      cat $i
    fi
  done
}

# Get instance info
function get_instance_info {
  TS="$(date +"%H-%M-%S")"
  (cat /etc/resolv.conf && \
    which systemd-resolve && \
      systemd-resolve --statistics && \
        cat /etc/systemd/resolved.conf) > \
          "/openstack/log/instance-info/host_dns_info_${TS}.log" || true
  tracepath "8.8.8.8" -m 5 > \
    "/openstack/log/instance-info/host_tracepath_info_${TS}.log" || true
  tracepath6 "2001:4860:4860::8888" -m 5 >> \
    "/openstack/log/instance-info/host_tracepath_info_${TS}.log" || true
  lxc-ls --fancy > \
    "/openstack/log/instance-info/host_lxc_container_info_${TS}.log" || true
  lxc-checkconfig > \
    "/openstack/log/instance-info/host_lxc_config_info_${TS}.log" || true
  (iptables -vnL && iptables -t nat -vnL && iptables -t mangle -vnL) > \
    "/openstack/log/instance-info/host_firewall_info_${TS}.log" || true
  ANSIBLE_HOST_KEY_CHECKING=False \
    ansible -i "localhost," localhost -m setup > \
      "/openstack/log/instance-info/host_system_info_${TS}.log" || true
  get_repos_info > \
    "/openstack/log/instance-info/host_repo_info_${TS}.log" || true

  determine_distro
  case ${DISTRO_ID} in
      centos|rhel|fedora)
          rpm -qa > \
            "/openstack/log/instance-info/host_packages_info_${TS}.log" || true
          ;;
      ubuntu|debian)
          dpkg-query --list > \
            "/openstack/log/instance-info/host_packages_info_${TS}.log" || true
          ;;
  esac
}

function print_report {
  # Print the stored report data
  echo -e "${REPORT_DATA}"
}

function get_pip {

  # check if pip is already installed
  if [ "$(which pip)" ]; then

    # make sure that the right pip base packages are installed
    # If this fails retry with --isolated to bypass the repo server because the repo server will not have
    # been updated at this point to include any newer pip packages.
    pip install --upgrade ${PIP_INSTALL_OPTIONS} || pip install --upgrade --isolated ${PIP_INSTALL_OPTIONS}

  # when pip is not installed, install it
  else

    # If GET_PIP_URL is set, then just use it
    if [ -n "${GET_PIP_URL:-}" ]; then
      curl --silent ${GET_PIP_URL} > /opt/get-pip.py
      if head -n 1 /opt/get-pip.py | grep python; then
        python /opt/get-pip.py ${PIP_INSTALL_OPTIONS}
        return
      fi
    fi

    # Try getting pip from bootstrap.pypa.io as a primary source
    curl --silent https://bootstrap.pypa.io/get-pip.py > /opt/get-pip.py
    if head -n 1 /opt/get-pip.py | grep python; then
      python /opt/get-pip.py ${PIP_INSTALL_OPTIONS}
      return
    fi

    # Try the get-pip.py from the github repository as a primary source
    curl --silent https://raw.githubusercontent.com/pypa/get-pip/master/get-pip.py > /opt/get-pip.py
    if head -n 1 /opt/get-pip.py | grep python; then
      python /opt/get-pip.py ${PIP_INSTALL_OPTIONS}
      return
    fi

    echo "A suitable download location for get-pip.py could not be found."
    exit_fail
  fi
}

## Signal traps --------------------------------------------------------------
# Trap all Death Signals and Errors
trap "exit_fail ${LINENO} $? 'Received STOP Signal'" SIGHUP SIGINT SIGTERM
trap "exit_fail ${LINENO} $?" ERR

## Pre-flight check ----------------------------------------------------------
# Make sure only root can run our script
if [ "$(id -u)" != "0" ]; then
  info_block "This script must be run as root"
  exit_state 1
fi

# Check that we are in the root path of the cloned repo
if [ ! -d "etc" -a ! -d "scripts" -a ! -d "playbooks" ]; then
  info_block "** ERROR **"
  echo "Please execute this script from the root directory of the cloned source code."
  echo -e "Example: /opt/openstack-ansible/\n"
  exit_state 1
fi


## Exports -------------------------------------------------------------------
# Export known paths
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

# Export the home directory just in case it's not set
export HOME="/root"
