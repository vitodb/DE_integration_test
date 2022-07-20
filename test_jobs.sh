#!/usr/bin/env bash

set -o pipefail
set -E

MYSCRIPTDIR=$( dirname ${0})/
DE_CERT_DIR=/var/de
BRANCH=${1}
SLACK_CH_REF=${2}

notify_slack()
{
    test_status=${1}
    unset slack_mention
    case ${test_status} in
        0) slack_status="good"; emoji_status=":heavy_check_mark:";;
        1) slack_status="danger"; emoji_status=":x:"; slack_mention=${slack_mention_on_failure:-@channel};;
        2) slack_status="unknown"; emoji_status=":grey_question:";;
        3) slack_status="warning"; emoji_status=":warning:";;
    esac


    slack_in_web_hook_to_notify=${SLACK_CH_REF}
    echo "slack_in_web_hook_to_notify: ${slack_in_web_hook_to_notify}"
    slack_in_web_hook_header="DE 2-channel test"

    slack_in_web_hook_message="${2}"

    OLDIFS="${IFS}"
    IFS=","
    for slack_in_web_hook_tmp in ${slack_in_web_hook_to_notify}; do
        curl -v --data-urlencode "payload={\"link_names\": 1, \"attachments\": [ { \"color\": \"${slack_status}\", \"title\":\"${slack_mention}\n${slack_in_web_hook_header} ${emoji_status}\", \"text\":\"${slack_in_web_hook_message}\", \"mrkdwn_in\": [ \"text\" ]} ] }" https://hooks.slack.com/services/${slack_in_web_hook_tmp}

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
    echo -e "\nCI MSG BEGIN\n Branch: ${1}\n Script: `basename ${0}`\n - error at line ${3}\n - command: ${4} \n exit status: ${2}\nCI MSG END\n"
    echo -e "To: "${MAILTOREPORT}"\nSubject: `basename ${0}` failed at `date`\nCI MSG BEGIN\n Branch: ${1}\n Script: `basename ${0}`\n - error at line ${3}\n - command: "${4}" \n - exit status: ${2}\n node: `hostname`\nCI MSG END\n" | /usr/sbin/sendmail -t ${MAILTOREPORT}

#     test_DE_summary=$( awk '/*** MSG BEGIN ***/,/*** MSG END ***/' <<< "${test_DE_output}" | sed -e 's#\*\*\* MSG .*##g ; s#"#'\''#g')
#     notify_slack ${1} 1 "${test_DE_summary}"

    echo -e "\n\n### ${0} exitstatus args: ${@} ###\n"

    echo "LASTERR: ${LASTERR} - trapmode ${5}"
    if [[ "${5}" = "EXIT" ]]; then
        if [[ "${LASTERR}" != "0" ]]; then
            echo " @@ `basename ${0}` exit status ${LASTERR} @@"
            exit ${LASTERR}
        else
            echo "All OK"
            return ${LASTERR}
        fi
    elif [[ "${5}" = "RETURN" ]]; then
        return ${LASTERR}
    else
        echo "Something was wrong"
        exit ${LASTERR}
    fi

}


test_jobs(){

    condor_q

    echo "*** MSG BEGIN ***"
    echo "de-client status for branch: ${BRANCH}"
    if [[ "${BRANCH}" == "1.7" ]]; then
        timeout -k 20 -s 15 30m de-client --status | grep -i state
    else
        timeout -k 20 -s 15 30m de-client --status
    fi
    echo "*** MSG END ***"

    sleep 1m

    nSTEADY_ch=$(timeout -k 20 -s 15 30m de-client --status | grep -i state | grep STEADY | wc -l || :)
    Expected_STEADY_ch=12
    if [[ "${BRANCH}" == "1.7" ]]; then
        Expected_STEADY_ch=2
    fi

    if [[ ${nSTEADY_ch} -ne ${Expected_STEADY_ch} ]]; then
        echo "*** MSG BEGIN ***"
        echo -e "There are ${nSTEADY_ch} channels active out of expected ${Expected_STEADY_ch},\nsomething is not right with DE."
        echo " @@ `basename ${0}` exit status 1 @@"
        echo "*** MSG END ***"
        return 1
    fi

    export X509_USER_PROXY=${DE_CERT_DIR}/de_cert.pem

    voms-proxy-info -all -file ${DE_CERT_DIR}/vo_proxy


    voms-proxy-info -exists -vo -valid 13:00 -file ${DE_CERT_DIR}/vo_proxy > /dev/null ||
    voms-proxy-init -rfc -dont-verify-ac -noregen -voms fermilab -valid 13:00 -out ${DE_CERT_DIR}/vo_proxy

    voms-proxy-info -all -file ${DE_CERT_DIR}/vo_proxy
    voms-proxy-info -all -file ${DE_CERT_DIR}/fe_proxy

    mkdir -p  ${MYSCRIPTDIR}/test_jobs/
    cd ${MYSCRIPTDIR}/test_jobs/

    condor_submit test_${BRANCH//\./_}.submit

    sleep 5

    condor_q

    #sleep 15m

    #timeout -k 20 -s 15 30m condor_watch_q -users decisionengine -exit all,done,0 -exit any,held,1
    # timeout -k 20 -s 15 30m condor_watch_q -users decisionengine -refresh -no-table -no-row-progress -no-progress -no-updated-at -abbreviate -no-color -exit all,done,0 -exit any,held,1 | grep -v "^\.\.\." | uniq
    # timeout -k 20 -s 15 30m condor_watch_q -users decisionengine -refresh -no-table -no-row-progress -no-progress -no-updated-at -abbreviate -no-color -exit all,done,0 -exit any,held,1
    condor_watch_q_out=$(
        timeout -k 20 -s 15 30m condor_watch_q -users decisionengine -refresh -no-table -no-row-progress -no-progress -no-updated-at -abbreviate -no-color -exit all,done,0 -exit any,held,1 -exit none,active,0
    )

    echo "*** MSG BEGIN ***"
    echo "test job status for branch: ${BRANCH}"
    echo "${condor_watch_q_out}" | grep -v "^\.\.\." | uniq
    echo "*** MSG END ***"

    condor_q

}

#trap 'LASTERR=$?; exitstatus ${BRANCH} ${LASTERR} ${LINENO} "${BASH_COMMAND}" RETURN' ERR
trap 'LASTERR=$?; exitstatus ${BRANCH} ${LASTERR} ${LINENO} "${BASH_COMMAND}" EXIT' ERR

# set -x

export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin

id
hostname

test_jobs

sendmail -bm vito@fnal.gov <<EOF
From: de_test@fnal.gov
To: vito@fnal.gov
Subject: DE test report ${BRANCH} $(hostname)
DE test message ${BRANCH} $(hostname)
EOF

if [ $? -eq 0 ]; then
    echo "report sent"
else
    echo "problem to send report"
fi
