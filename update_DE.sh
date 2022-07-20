#!/usr/bin/env bash

# set -x
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:${PATH}
set -o pipefail
set -E

MYSCRIPTDIR=$( dirname ${0})/
DEPKGDIR=/root/decisionengine/packages
DE_CERT_DIR=/var/de
SLACK_CH_REF=${1}

notify_slack()
{
    BRANCH=${1}
    test_status=${2}
    unset slack_mention
    case ${test_status} in
        0) slack_status="good"; emoji_status=":heavy_check_mark:";;
        1) slack_status="danger"; emoji_status=":x:"; slack_mention=${slack_mention_on_failure:-@channel};;
        2) slack_status="unknown"; emoji_status=":grey_question:";;
        3) slack_status="warning"; emoji_status=":warning:";;
    esac


    slack_in_web_hook_to_notify=${SLACK_CH_REF}
    echo "slack_in_web_hook_to_notify: ${slack_in_web_hook_to_notify}"
    slack_in_web_hook_header="DE integration test branch ${BRANCH} on $(hostname)"

    slack_in_web_hook_message="${3}"

    OLDIFS="${IFS}"
    IFS=","
    for slack_in_web_hook_tmp in ${slack_in_web_hook_to_notify}; do
        curl -v --data-urlencode "payload={\"link_names\": 1, \"attachments\": [ { \"color\": \"${slack_status}\", \"title\":\"${slack_mention}\n${slack_in_web_hook_header} ${emoji_status}\", \"text\":\"\`\`\`${slack_in_web_hook_message}\`\`\`\", \"mrkdwn_in\": [ \"text\" ]} ] }" https://hooks.slack.com/services/${slack_in_web_hook_tmp}

        echo
        echo "test_status: ${test_status}"
        echo "slack_in_web_hook_tmp: ${slack_in_web_hook_tmp}"
        echo "slack_in_web_hook_header: ${slack_in_web_hook_header}"
        echo "slack_in_web_hook_message: ${slack_in_web_hook_message}"
    done
    IFS="${OLDIFS}"

}

exitstatus()
{
    MAILTOREPORT=vito@fnal.gov
    echo -e "\nCI MSG BEGIN\n Branch: ${1}\nScript: `basename ${0}`\n - error at line ${3}\n - command: ${4} \n exit status: ${2}\nCI MSG END\n"
    echo -e "To: "${MAILTOREPORT}"\nSubject: `basename ${0}` failed at `date`\nCI MSG BEGIN\nBranch: ${1}\n Script: `basename ${0}`\n - error at line ${3}\n - command: "${4}" \n - exit status: ${2}\n node: `hostname`\nCI MSG END\n" | /usr/sbin/sendmail -t ${MAILTOREPORT}

    test_DE_summary=$( awk '/*** MSG BEGIN ***/,/*** MSG END ***/' <<< "${test_DE_output}" | sed -e 's#\*\*\* MSG .*##g ; s#"#'\''#g')

    echo -e "\n\n### ${0} exitstatus args: ${@} ###\n"

    echo "LASTERR: ${LASTERR} - trapmode ${5}"
    if [[ "${5}" = "EXIT" ]]; then
        if [[ "${LASTERR}" != "0" ]]; then
            echo " @@ `basename ${0}` exit status ${LASTERR} @@"
            notify_slack ${1} 1 "${test_DE_summary}"
            exit ${LASTERR}
        else
            notify_slack ${1} 0 "${test_DE_summary}"
            echo "All OK"
            return ${LASTERR}
        fi
    elif [[ "${5}" = "RETURN" ]]; then
        exit ${LASTERR}
        return ${LASTERR}
    else
        notify_slack ${1} 1 "${test_DE_summary}"
        echo "Something was wrong"
        exit ${LASTERR}
    fi

}



test_DE()
{

    trap 'LASTERR=$?; exitstatus ${BRANCH} ${LASTERR} ${LINENO} "${BASH_COMMAND}" RETURN' ERR
    echo "test_DE()"
    BRANCH=${1}

    DE_CERT=${DE_CERT_DIR}/de_cert.pem
    DE_CERT_TMP=${DE_CERT_DIR}/de_cert_tmp.pem

    ls -lh ${DE_CERT_TMP} ${DE_CERT}
    ksu vito -e /usr/bin/kcron kx509 -n --minhours 13 -o ${DE_CERT_TMP}
    ls -lh ${DE_CERT_TMP} ${DE_CERT}

    cp -av ${DE_CERT_TMP} ${DE_CERT}

    ls -lh ${DE_CERT_TMP} ${DE_CERT}

    /usr/bin/chmod 600 ${DE_CERT}
    /usr/bin/chown decisionengine: ${DE_CERT}

    ls -lh ${DE_CERT_TMP} ${DE_CERT}

    mkdir -p ${DEPKGDIR}
    cd ${DEPKGDIR}

    yum list decisionengine decisionengine_modules || :

    ls -lh

    python3 ${MYSCRIPTDIR}/DE_builds.py -j decisionengine_modules_pipeline -b ${BRANCH}
    python3 ${MYSCRIPTDIR}/DE_builds.py -j decisionengine_pipeline -b ${BRANCH}

    ls -lh

    systemctl status decisionengine.service && systemctl stop decisionengine.service || :
    systemctl status decisionengine.service || :

    export PG_VERSION=12
    export PATH="/usr/pgsql-${PG_VERSION}/bin:~/.local/bin:$PATH"

    dropdb -U postgres decisionengine
    createdb -U postgres decisionengine

    TODAY=$(date +%F)

    yum -y erase decisionengine decisionengine_modules

    yum -y --setopt=skip_missing_names_on_install=False install ${DEPKGDIR}/decisionengine-${BRANCH}-${TODAY}-* ${DEPKGDIR}/decisionengine_modules-${BRANCH}-${TODAY}-*


    yum list decisionengine decisionengine_modules

    ### check redis service status
    if ! podman ps -a --format "{{.Names}}  {{.Status}}" | grep decisionengine-redis; then
        ## no running decisionengine-redis container, run it!
        podman run --name decisionengine-redis -p 127.0.0.1:6379:6379 -d redis:6 --loglevel verbose
        podman ps -a
    else
        ## there is a decisionengine-redis container, restart it
        podman stop decisionengine-redis | xargs podman rm -f
        podman run --name decisionengine-redis -p 127.0.0.1:6379:6379 -d redis:6 --loglevel verbose
        podman ps -a
    fi

    ### update configurations to request glideins specific for the branch
    rm -fv /etc/decisionengine/config.d/{job_classification*,resource_request*}
    if [[ "${BRANCH}" == "master" ]]; then
        /bin/cp -va /etc/decisionengine/config.d/2.0/* /etc/decisionengine/config.d/
    elif [[ "${BRANCH}" == "2.0" ]]; then
        /bin/cp -va /etc/decisionengine/config.d/2.0/* /etc/decisionengine/config.d/
    elif [[ "${BRANCH}" == "1.7" ]]; then
        /bin/cp -va /etc/decisionengine/config.d/1.7/* /etc/decisionengine/config.d/
        sed 's/@FE_GRP@/de_test_'${BRANCH//\./_}'/' /etc/decisionengine/config.d/job_classification.jsonnet_template > /etc/decisionengine/config.d/job_classification.jsonnet
        sed 's/@ACCOUNTING_GRP@/de_test_'${BRANCH//\./_}'/' /etc/decisionengine/config.d/resource_request.jsonnet_template > /etc/decisionengine/config.d/resource_request.jsonnet
        /bin/cp -va  /etc/decisionengine/decision_engine.jsonnet{.1.7,}
    fi

    systemctl start decisionengine.service
    systemctl status decisionengine.service

    sleep 5

    voms-proxy-info -exists -valid 50:00 -file ${DE_CERT_DIR}/fe_proxy > /dev/null ||
       grid-proxy-init -cert /etc/grid-security/hostcert.pem -key /etc/grid-security/hostkey.pem -valid 999:0 -out ${DE_CERT_DIR}/fe_proxy

    chown -R decisionengine: ${DE_CERT_DIR}/fe_proxy

#     set -x
    test_jobs_log=$(ksu decisionengine -e ${MYSCRIPTDIR}/test_jobs.sh ${BRANCH} ${SLACK_CH_REF})

    echo -e "\n\n#### test_jobs_log ${BRANCH}:"
    echo "${test_jobs_log}"

#     if egrep "@@ .* exit status .* @@" <<< "${test_jobs_log}"; then
#         return 1
#     fi

    ## we can stop DE service
    systemctl status decisionengine.service || :
    systemctl stop decisionengine.service
    systemctl status decisionengine.service || :

    ## we can now delete redis DB and stop it
    podman stop decisionengine-redis | xargs podman rm -f
    podman ps -a

}


for BRANCH in master 2.0; do

    # trap 'LASTERR=$?; exitstatus ${BRANCH} ${LASTERR} ${LINENO} "${BASH_COMMAND}" RETURN' ERR

    echo -e "\n*** DATE: \c"
    date
    echo "Testing branch: ${BRANCH}"
    test_DE_output=$(test_DE ${BRANCH} 2>&1)
    test_DE_exit_code=${?}
    echo "Tested branch: ${BRANCH} - with exit code: ${test_DE_exit_code}"

    echo "${test_DE_output}"

    test_DE_summary=$( awk '/*** MSG BEGIN ***/,/*** MSG END ***/' <<< "${test_DE_output}" | sed -e 's#\*\*\* MSG .*##g ; s#"#'\''#g')

    echo "Test completed for branch: ${BRANCH}"
    echo "test_DE_summary: ${test_DE_summary}"
    egrep "@@ .* exit status .* @@" <<< "${test_DE_summary}" || :

    if [[ ${test_DE_exit_code} -ne 0 || $(egrep "@@ .* exit status .* @@" <<< "${test_DE_summary}") ]]; then
        echo "Error detected in test_DE_summary"
        notify_slack ${BRANCH} 1 "${test_DE_summary}"
    else
        echo "test_DE_summary is OK"
        notify_slack ${BRANCH} 0 "${test_DE_summary}"
    fi

    ### if egrep "@@ .* exit status .* @@" <<< "${test_DE_summary}"; then
    ###     echo "Error detected in test_DE_summary"
    ###     notify_slack ${BRANCH} 1 "${test_DE_summary}"
    ### else
    ###     echo "test_DE_summary is OK"
    ###     notify_slack ${BRANCH} 0 "${test_DE_summary}"
    ### fi

    echo -e "\n*** DATE: \c"
    date
done
