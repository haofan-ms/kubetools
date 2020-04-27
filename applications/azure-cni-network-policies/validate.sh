#!/bin/bash -e

FILE_NAME=$0

SCRIPT_LOCATION=$(dirname $FILENAME)
COMMON_SCRIPT_FILENAME="common.sh"
GIT_REPROSITORY="${GIT_REPROSITORY:-haofan-ms/kubetools}"
GIT_BRANCH="${GIT_BRANCH:-update-cni}"

# Download common script file.
curl -o $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME \
https://raw.githubusercontent.com/$GIT_REPROSITORY/$GIT_BRANCH/applications/common/$COMMON_SCRIPT_FILENAME
if [ ! -f $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME ]; then
    echo "File($COMMON_SCRIPT_FILENAME) failed to download."
    exit 1
fi

source $SCRIPT_DIRECTORY/$COMMON_SCRIPT_FILENAME

###########################################################################################################
# The function will read parameters and populate below global variables.
# IDENTITY_FILE, MASTER_IP, OUTPUT_SUMMARYFILE, USER_NAME
parse_commandline_arguments $@

if [ -z "$OUTPUT_SUMMARYFILE" ]; then
    log_level -e "Summary file not set."
    echo "Summary file not set."
    exit 1
fi

###########################################################################################################
# Define all inner varaibles.

OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/validate.log"
touch $LOG_FILENAME

{
    if [[ -z $IDENTITY_FILE ]]; then
        log_level -e "IDENTITY_FILE not set."
        printf "IDENTITY_FILE not set." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    if [[ -z $MASTER_IP ]]; then
        log_level -e "MASTER_IP not set."
        printf "MASTER_IP not set." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    if [[ -z $USER_NAME ]]; then
        log_level -e "USER_NAME not set."
        printf "USER_NAME not set." > $OUTPUT_SUMMARYFILE
        exit 1
    fi
    
    TEST_DIRECTORY="/home/$USER_NAME/azure-cni-network-policies"
    APPLICATION_NAME="Azure_CNI_network_policies"
    NETWORK_POLICY_FILENAME="network_policy.yaml"
    NGINX_WELCOME="Welcome to nginx!"
    GOOGLE_INFO="Search the world's information"
    DOWNLOAD_TIMEDOUT="download timed out"
    BAD_ADDRESS="bad address"
    BUSYBOX_DEPLOY_FILENAME="busybox_deploy.yaml"

    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Script Parameters"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "GIT_REPROSITORY:          : $GIT_REPROSITORY"
    log_level -i "GIT_BRANCH:               : $GIT_BRANCH"
    log_level -i "IDENTITY_FILE             : $IDENTITY_FILE"
    log_level -i "MASTER_IP                 : $MASTER_IP"
    log_level -i "OUTPUT_SUMMARYFILE        : $OUTPUT_SUMMARYFILE"
    log_level -i "USER_NAME                 : $USER_NAME"
    log_level -i "TEST_DIRECTORY            : $TEST_DIRECTORY"
    log_level -i "NETWORK_POLICY_FILENAME   : $NETWORK_POLICY_FILENAME"
    log_level -i "NGINX_WELCOME             : $NGINX_WELCOME"
    log_level -i "DOWNLOAD_TIMEDOUT         : $DOWNLOAD_TIMEDOUT"
    log_level -i "BUSYBOX_DEPLOY_FILENAME   : $BUSYBOX_DEPLOY_FILENAME"
    log_level -i "------------------------------------------------------------------------"
    
    log_level -i "Evaluate log from busybox-ingress pod"
    validate_ingress_access=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_ingress_log.txt" | grep "$NGINX_WELCOME")
    if [[ -z $validate_ingress_access ]]; then
        log_level -e "Failed to access nginx pod." 
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Failed to access nginx pod." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    log_level -i "Evaluate log from busybox-egress pod"
    validate_egress_access=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_egress_log.txt" | grep "$GOOGLE_INFO")
    if [[ -z $validate_egress_access ]]; then
        log_level -e "Failed to access Google website." 
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Failed to access Google website." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    log_level -i "Evaluate connectivity to nginx load balander"
    SERVICE_NAME="nginx-lb"
    check_app_has_externalip $IDENTITY_FILE \
        $USER_NAME \
        $MASTER_IP \
        $APPLICATION_NAME \
        $SERVICE_NAME
     if [[ $? != 0 ]]; then
        result="failed"
        log_level -e "Public IP address did not get assigned for service($SERVICE_NAME)."
        printf '{"result":"%s","error":"%s"}\n' "$result" "Azure CNI network failed to assign public IP." > $OUTPUT_SUMMARYFILE
        exit 1
    else
        check_app_listening_at_externalip $IP_ADDRESS
        if [[ $? != 0 ]]; then
            result="failed"
            log_level -e "Not able to communicate to public IP($IP_ADDRESS) for service($SERVICE_NAME)."
            printf '{"result":"%s","error":"%s"}\n' "$result" "Azure CNI network failed to connect to public IP." > $OUTPUT_SUMMARYFILE
        exit 1
        fi
    fi

    log_level -i "Delete the old busybox pods"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl delete -f $BUSYBOX_DEPLOY_FILENAME";sleep 60

    log_level -i "Create network policy rule to block ingress traffic to nginx pod and egress traffic to Google website"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl create -f $NETWORK_POLICY_FILENAME";sleep 10
    network_policy_create=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get networkPolicy -o json > network_policy.json")

    network_policy_ingress_status=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat network_policy.json | jq '.items[]."metadata"."name"'" | grep "azure-cni-block-ingress")

    if [ $? == 0 ]; then
        log_level -i "Created Azure CNI network ingress policy."
    else    
        log_level -e "Azure CNI network ingress policy creation failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Azure CNI network ingress policy creation was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 

    network_policy_egress_status=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat network_policy.json | jq '.items[]."metadata"."name"'" | grep "azure-cni-block-egress")

    if [ $? == 0 ]; then
        log_level -i "Created Azure CNI network egress policy."
    else    
        log_level -e "Azure CNI network egress policy creation failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Azure CNI network egress policy creation was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 

    network_policy_external_status=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat network_policy.json |  jq '.items[]."metadata"."name"'" | grep "azure-cni-block-nginxlb")

    if [ $? == 0 ]; then
        log_level -i "Created Azure CNI network external policy."
    else    
        log_level -e "Azure CNI network external policy creation failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Azure CNI network external policy creation was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    log_level -i "Create and evaluate log from busybox pods again"
    busybox_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl create -f $BUSYBOX_DEPLOY_FILENAME";sleep 30)

    busybox_ingress_deploy_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get pod busybox-ingress -o json > busybox_ingress_pod_new.json")
    busybox_ingress_status_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_ingress_pod_new.json | jq '."status"."conditions"[1].type'" | grep "Ready")

    if [ $? == 0 ]; then
        log_level -i "Deployed new busybox ingress pod."
    else    
        log_level -e "New busybox ingress deployment failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "New busybox ingress deployment was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 

    busybox_egress_deploy_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get pod busybox-egress -o json > busybox_egress_pod_new.json")
    busybox_egress_status_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_egress_pod_new.json | jq '."status"."conditions"[1].type'" | grep "Ready")

    if [ $? == 0 ]; then
        log_level -i "Deployed new busybox egress pod."
    else    
        log_level -e "New busybox egress deployment failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "New busybox egress deployment was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 

    busybox_ingress_log_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl logs busybox-ingress > busybox_ingress_log_new.txt")
    validate_ingress_blocks=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_ingress_log_new.txt" | grep "$DOWNLOAD_TIMEDOUT")
    if [[ -z $validate_ingress_blocks ]]; then
        log_level -e "Failed to block access to nginx pod." 
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Network Policy failed to block ingress traffic." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    busybox_egress_log_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl logs busybox-egress > busybox_egress_log_new.txt")
    validate_egress_blocks=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_egress_log_new.txt" | grep "$BAD_ADDRESS")
    if [[ -z $validate_egress_blocks ]]; then
        log_level -e "Failed to block access to Google website." 
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Network Policy failed to block egress traffic." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    check_app_listening_at_externalip $IP_ADDRESS
    if [[ $? == 0 ]]; then
        result="failed"
        log_level -e "Failed to block external access to nginx load balancer"
    fi

    log_level -i "All tests passed" 
    log_level -i "=========================================================================="
    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_SUMMARYFILE
} \
2>&1 | tee $LOG_FILENAME