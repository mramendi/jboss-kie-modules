#!/bin/bash

source /usr/local/s2i/scl-enable-maven
source "${JBOSS_HOME}/bin/launch/logging.sh"
source "${JBOSS_HOME}/bin/launch/jboss-kie-wildfly-security-login-modules.sh"

function prepareEnv() {
    # please keep these in alphabetical order
    unset KIE_MBEANS
    unset_kie_security_auth_env
}

function configureEnv() {
    configure
}

function configure() {
    configure_maven_settings
    configure_mbeans
    configure_auth_login_modules
}

function configure_maven_settings() {
    # env var used by KIE to first find and load global settings.xml
    local m2Home=$(mvn -v | grep -i 'maven home: ' | sed -E 's/^.{12}//')
    export M2_HOME="${m2Home}"
    # see scripts/jboss-kie-wildfly-common/configure.sh
    # used by KIE to then override with custom settings.xml
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dkie.maven.settings.custom=${HOME}/.m2/settings.xml"
}

function configure_mbeans() {
    # should jmx mbeans be enabled? (true/false becomes enabled/disabled)
    local kieMbeans="enabled"
    if [ "x${KIE_MBEANS}" != "x" ]; then
        # if specified, respect value
        local km=$(echo "${KIE_MBEANS}" | tr "[:upper:]" "[:lower:]")
        if [ "${km}" != "true" ] && [ "${km}" != "enabled" ]; then
            kieMbeans="disabled"
        fi
    fi
    JBOSS_KIE_ARGS="${JBOSS_KIE_ARGS} -Dkie.mbeans=${kieMbeans} -Dkie.scanner.mbeans=${kieMbeans}"
}

# Queries the Route from the Kubernetes API
# ${1} - route name
query_route() {
    local routeName=${1}
    # only execute the following lines if this container is running on OpenShift
    if [ -e /var/run/secrets/kubernetes.io/serviceaccount/token ]; then
        local namespace=$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace)
        local token=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
        local response=$(curl -s -w "%{http_code}" --cacert /var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
            -H "Authorization: Bearer $token" \
            -H 'Accept: application/json' \
            https://${KUBERNETES_SERVICE_HOST:-kubernetes.default.svc}:${KUBERNETES_SERVICE_PORT:-443}/apis/route.openshift.io/v1/namespaces/${namespace}/routes/${routeName})
        echo ${response}
    fi
}

# Queries the Route host from the Kubernetes API
# ${1} - route name
# ${2} - default host
query_route_host() {
    local routeName=${1}
    local host=${2}
    if [ "${routeName}" != "" ]; then
        local response=$(query_route "${routeName}")
        if [ "${response: -3}" = "200" ]; then
            # parse the json response to get the route host
            host=$(echo ${response::- 3} | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["spec"]["host"]')
        else
            log_warning "Fail to query the Route using the Kubernetes API, the Service Account might not have the necessary privileges; defaulting to host [${host}]."
            if [ ! -z "${response}" ]; then
                log_warning "Response message: ${response::- 3} - HTTP Status code: ${response: -3}"
            fi
        fi
    fi
    echo "${host}"
}

# Queries the Route service from the Kubernetes API
# ${1} - route name
query_route_service() {
    local routeName=${1}
    local service
    if [ "${routeName}" != "" ]; then
        local response=$(query_route "${routeName}")
        if [ "${response: -3}" = "200" ]; then
            # parse the json response to get the route service
            service=$(echo ${response::- 3} | python -c 'import json,sys;obj=json.load(sys.stdin);print obj["spec"]["to"]["name"]')
        else
            log_warning "Fail to query the Route using the Kubernetes API, the Service Account might not have the necessary privileges."
            if [ ! -z "${response}" ]; then
                log_warning "Response message: ${response::- 3} - HTTP Status code: ${response: -3}"
            fi
        fi
    fi
    echo "${service}"
}

# Queries the Route service host from the Kubernetes API and Environment
# ${1} - route name
query_route_service_host() {
    local routeName=${1}
    local host=${2}
    if [ "${routeName}" != "" ]; then
        local service=$(query_route_service "${routeName}")
        if [ "${service}" != "" ]; then
            service=${service//-/_}
            service=${service^^}
            host=$(find_env "${service}_SERVICE_HOST" "${host}")
        fi
    fi
    echo "${host}"
}

# Builds a simple URL
# ${1} - protocol (default is http)
# ${2} - host (default is $HOSTNAME if possible, or localhost)
# ${3} - port (default is empty)
# ${4} - path (default is empty)
build_simple_url() {
    local protocol=${1:-http}
    local host=${2:-${HOSTNAME:-localhost}}
    local port=${3}
    local path=${4}
    if [ "${port}" != "" ]; then
        port=":${port}"
    fi
    echo "${protocol}://${host}${port}${path}"
}

# Builds a Route URL by querying the Kubernetes API
# ${1} - route name
# ${2} - default protocol
# ${3} - default host
# ${4} - default port
# ${5} - path
build_route_url() {
    local routeName=${1}
    local protocol=${2}
    local host=${3}
    local port=${4}
    local path=${5}
    if [ "${routeName}" != "" ]; then
        if [[ "${routeName},," = *"secure"* ]]; then
            protocol="${protocol:-https}"
            port="${port:-443}"
        fi
        host=$(query_route_host "${routeName}" "${host}")
    fi
    echo $(build_simple_url "${protocol}" "${host}" "${port}" "${path}")
}
