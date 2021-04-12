#!/usr/bin/env bash
# T.A.D.S. terraform command
#
# Usage: ./tads terraform ENVIRONMENT COMMAND
#

set -euo pipefail

readonly SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SELF_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly ROOT_PATH="$(cd "${SELF_PATH}/../.." && pwd)"

readonly TADS_MIN_TERRAFORM_VERSION="0.13"

# shellcheck source=scripts/includes/common.sh
source "${SELF_PATH}/../includes/common.sh"

usage() {
    local cmd="./tads"

    local environments
    # shellcheck disable=SC2012
    environments="$(ls -1 "${ROOT_PATH}/terraform/environments" | awk '{ print "    " $1 }')"

    cat <<- EOF

Usage: ${cmd} terraform ENVIRONMENT COMMAND

Use Terraform to create VMs on your cloud provider

COMMANDS:
    init                    Init Terraform environment
    apply                   Apply Terraform changes
    gen-ansible-inventory   Force the corresponding Ansible inventory generation;
                             this is done automatically after each "apply" command
    ...                     ...

To list other Terraform commands and options, run: terraform -help

ENVIRONMENTS:
${environments}


EOF
    exit 1
}

terraform_cmd() {
    if ! command -v terraform > /dev/null; then
        echo_red "Terraform must be installed on your local machine. Please referer to README.md to see how."
        exit 1
    fi

    local current_terraform_version
    current_terraform_version="$(terraform --version | head -n1 | cut -d " " -f2 | cut -c2- || true)"

    if ! is_version_gte "${current_terraform_version}" "${TADS_MIN_TERRAFORM_VERSION}"; then
        echo_red "Your Terraform version (${current_terraform_version}) is not supported by T.A.D.S."
        echo_red "Please upgrade it to at least version ${TADS_MIN_TERRAFORM_VERSION}"
        exit 1
    fi

    local environment="$1"
    shift
    if [[ ! -d "${ROOT_PATH}/terraform/environments/${environment}" ]]; then
        echo_red "Terraform ENVIRONMENT does not exist: ${environment}"
        exit 1
    fi

    local command="$1"

    if [[ ! "${command}" == "gen-ansible-inventory" ]]; then
        [[ "${TADS_VERBOSE:-}" == true ]] &&  set -x
        (cd "${ROOT_PATH}/terraform/environments/${environment}"; terraform "$@")
        set +x
    fi

    if [[ "${command}" == "apply" || "${command}" == "gen-ansible-inventory" ]]; then
        gen_ansible_inventory_from_terraform "${environment}"
    fi
}

gen_ansible_inventory_from_terraform () {
    local environment="$1"
    local inventory_path="${ROOT_PATH}/ansible/inventories/${environment}"

    echo "Generating Ansible inventory from Terraform outputs..."

    local ssh_user
    local manager_ips
    local worker_ips
    ssh_user="$(terraform_cmd "${environment}" output ssh_user)"
    manager_ips="$(terraform_cmd "${environment}" output -json manager_ips | jq -r '.[]')"
    worker_ips="$(terraform_cmd "${environment}" output -json worker_ips 2>/dev/null | jq -r '.[]')"

    echo "# Inventory file for ${environment} environment" > "${inventory_path}"
    {
        echo "# Automatically generated by ./tads terraform"
        echo ""
        echo "# Manager nodes"
    } >> "${inventory_path}"

    local manager_index=1
    for manager_ip in ${manager_ips}; do
        echo "manager-${manager_index} ansible_user=${ssh_user} ansible_host=${manager_ip}" >> "${inventory_path}"
        manager_index=$((manager_index+1))
    done

    {
        echo ""
        echo "# Worker nodes"
    } >> "${inventory_path}"

    local worker_index=1
    for worker_ip in ${worker_ips}; do
        echo "worker-${worker_index} ansible_user=${ssh_user} ansible_host=${worker_ip}" >> "${inventory_path}"
        worker_index=$((worker_index+1))
    done

    local manager_nodes="manager-[1:$((manager_index-1))]"
    local worker_nodes
    worker_nodes=$([[ -n ${worker_ips} ]] && echo "worker-[1:$((worker_index-1))]")

cat <<EOT >> "${inventory_path}"

[${environment}]
${manager_nodes}
${worker_nodes}

[docker:children]
${environment}

[${environment}_encrypted:children]
${environment}

[dockerswarm_manager]
${manager_nodes}

[dockerswarm_worker]
${worker_nodes}

[docker:vars]
dockerswarm_iface=eth0
EOT

    echo "Inventory file generated: ${inventory_path}"
}

main () {
    if [[ "$#" -lt 2 ]]; then
        usage
    fi

    terraform_cmd "$@"
}

main "$@"
