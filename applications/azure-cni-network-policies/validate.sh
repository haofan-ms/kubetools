#!/bin/bash -e

FILE_NAME=$0
SCRIPT_FOLDER="$(dirname $FILE_NAME)"

COMMON_SCRIPT_FILENAME="common.sh"
source $SCRIPT_FOLDER/$COMMON_SCRIPT_FILENAME

###########################################################################################################
# The function will read parameters and populate below global variables.
# IDENTITY_FILE, MASTER_IP, OUTPUT_SUMMARYFILE, USER_NAME
parse_commandline_arguments $@

log_level -i "------------------------------------------------------------------------"
log_level -i "                Input Parameters"
log_level -i "------------------------------------------------------------------------"
log_level -i "IDENTITY_FILE       : $IDENTITY_FILE"
log_level -i "MASTER_IP           : $MASTER_IP"
log_level -i "OUTPUT_SUMMARYFILE  : $OUTPUT_SUMMARYFILE"
log_level -i "USER_NAME           : $USER_NAME"
log_level -i "------------------------------------------------------------------------"

if [[ -z "$IDENTITY_FILE" ]] || \
[[ -z "$MASTER_IP" ]] || \
[[ -z "$USER_NAME" ]] || \
[[ -z "$OUTPUT_SUMMARYFILE" ]]; then
    log_level -e "One of the mandatory parameter is not passed correctly."
    print_usage
    exit 1
fi
###########################################################################################################
# Define all inner varaibles.

OUTPUT_FOLDER="$(dirname $OUTPUT_SUMMARYFILE)"
LOG_FILENAME="$OUTPUT_FOLDER/validate.log"
touch $LOG_FILENAME

{
    TEST_DIRECTORY="/home/$USER_NAME/azure-cni-network-policies"
    NETWORK_POLICY_FILENAME="network_policy.yaml"
    NGINX_WELCOME="Welcome to nginx!"
    DOWNLOAD_TIMEDOUT="download timed out"
    BUSYBOX_DEPLOY_FILENAME="busybox_deploy.yaml"

    \
    log_level -i "------------------------------------------------------------------------"
    log_level -i "                Inner Variables"
    log_level -i "------------------------------------------------------------------------"
    log_level -i "TEST_DIRECTORY            : $TEST_DIRECTORY"
    log_level -i "NGINX_WELCOME             : $NGINX_WELCOME"
    log_level -i "DOWNLOAD_TIMEDOUT         : $DOWNLOAD_TIMEDOUT"
    log_level -i "BUSYBOX_DEPLOY_FILENAME   : $BUSYBOX_DEPLOY_FILENAME"
    log_level -i "------------------------------------------------------------------------"
    
    log_level -i "Evaluate Log from busybox Pod"
    if ! grep -q "$NGINX_WELCOME" "busybox_log.txt"; then
        log_level -e "Failed to access nginx pod." 
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Failed to access nginx pod." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    log_level -i "Create Network Policy rule to block ingress traffic to nginx pod"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl create -f $NETWORK_POLICY_FILENAME";sleep 10
    network_policy_create=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get networkPolicy -o json > network_policy.json")
    network_policy_status=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat network_policy.json | jq '.items[0]."metadata"."name"'" | grep "azure-cni";sleep 2m)

    if [ $? == 0 ]; then
        log_level -i "Created Azure CNI network policy."
    else    
        log_level -e "Azure CNI network policy creation failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Azure CNI network policy creation was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 

    log_level -i "Delete the old busybox pod"
    ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl delete pod busybox";sleep 60
    
    log_level -i "Create and evaluate log from busybox Pod again"
    busybox_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl create -f $BUSYBOX_DEPLOY_FILENAME";sleep 10)
    busybox_deploy_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl get pod -o json > busybox_pod_new.json")
    busybox_status_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;cat busybox_pod_new.json | jq '.items[0]."status"."conditions"[1].type'" | grep "Ready";sleep 2m)
    busybox_log_new=$(ssh -t -i $IDENTITY_FILE $USER_NAME@$MASTER_IP "cd $TEST_DIRECTORY;kubectl logs busybox > busybox_log_new.txt")

    if [ $? == 0 ]; then
        log_level -i "Deployed new busybox pod."
    else    
        log_level -e "New busybox deployment failed."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "New busybox deployment was not successfull." > $OUTPUT_SUMMARYFILE
        exit 1
    fi 

    if ! grep -q "$DOWNLOAD_TIMEDOUT" "busybox_log_new.txt"; then
        log_level -e "Network Policy failed to block ingress traffic."
        result="failed"
        printf '{"result":"%s","error":"%s"}\n' "$result" "Network Policy failed to block ingress traffic." > $OUTPUT_SUMMARYFILE
        exit 1
    fi

    log_level -i "All tests passed" 
    log_level -i "=========================================================================="
    result="pass"
    printf '{"result":"%s"}\n' "$result" > $OUTPUT_SUMMARYFILE
} \
2>&1 | tee $LOG_FILENAME