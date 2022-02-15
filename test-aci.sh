#!/bin/bash
clear && SWD=$(dirname "$0")

# USAGE SAMPLES
#
#   run test with a container group created in the same location as the target resource group
#	./test-aci.sh -s '672fab42-9efc-4f65-9b3c-dd6144e4ef60' -g 'aci-test-westeurope'
#
#	delete all existing container groups in the target resource group 
#	./test-aci.sh -s '672fab42-9efc-4f65-9b3c-dd6144e4ef60' -g 'aci-test-westeurope' -a true
#
#	use a polling timeout other than the default 5 mins (300 seconds)
#	./test-aci.sh -s '672fab42-9efc-4f65-9b3c-dd6144e4ef60' -g 'aci-test-westeurope' -t 120

while getopts s:g:l:r:t: flag
do
    case "${flag}" in
        s) subscription=${OPTARG};;			# the subscription to deploy to
        g) resourcegroup=${OPTARG};;		# the resource group to deploy to
		l) location=${OPTARG};;				# the location of the container group
        r) reset=${OPTARG};;				# reset/delete all existing container groups 
		t) timeout=$((${OPTARG} + 0))		# define the timeout when waiting for a 200 status code (default is 300)
    esac
done

# use a default timeout of 5 min
[[ $timeout -eq 0 ]] && timeout=300

header() {
	echo -e "\n========================================================================================================================="
	echo -e $1
	echo -e "-------------------------------------------------------------------------------------------------------------------------\n"
}

waitForWebServer() {

	SPIN='-\|/'
	
	cat <<-EOF
	
	Waiting for $2 ($1) to reach running state

	EOF

	while true; do

		CONTAINER_STATE="$(az container show --ids $2 --query 'instanceView.state' -o tsv)"
		[ "$CONTAINER_STATE" == "Running" ] && echo "done (State == $CONTAINER_STATE)" && break 
	
		i=$(( (i+1) %4 ))
		printf "  ${SPIN:$i:1} $CONTAINER_STATE ...\r"

	done 

	cat <<-EOF
	
	Waiting for $2 ($1) to respond with status code 200 on HTTP GET

	EOF

	while true; do

		STATUS_CODE="$(curl -s -o /dev/null -I -L -m 1 -f -w '%{http_code}' http://$1)"
		[ "200" == "$STATUS_CODE" ] && echo "done (StatusCode == $STATUS_CODE)" && break

		i=$(( (i+1) %4 ))
		printf "  ${SPIN:$i:1} $STATUS_CODE ...\r"

	done 
}

export -f waitForWebServer

if [ "true" == "$reset" ]; then

	resourceIds=$(az container list --subscription $subscription --resource-group $resourcegroup --query '[].id' -o tsv)

	[ ! -z "$resourceIds" ] \
		&& header "Deleting container groups" \
		&& echo "$resourceIds" \
		&& az container delete \
			--ids $resourceIds \
			--yes \
			--only-show-errors \
			-o none

fi

header "Deploying container group"

if [ -z "$location"]; then

	location="$(az group show --subscription $subscription --name $resourcegroup --query 'location' -o tsv)"
	echo -e "Use the location of the target resource group ($location) as no location was given\n"

fi

json=$(az container create \
	--subscription "$subscription" \
	--resource-group "$resourcegroup" \
	--location "$location" \
	--name "$(uuidgen)" \
	--image nginx \
	--ports 80 443 \
	--restart-policy "Never" \
	--dns-name-label "$(echo $RANDOM | md5sum | head -c 10)")

containerGroupId="$(echo $json | jq --raw-output '.id')"
containerGroupName="$(echo $json | jq --raw-output '.name')"
containerGroupFqdn="$(echo $json | jq --raw-output '.ipAddress.fqdn')"

[ -z "$containerGroupId" ] && exit 1

cat <<EOF

Container Group 
- Id:      $containerGroupId
- Name:    $containerGroupName
- Fqdn:    $containerGroupFqdn

URLs
- Portal:  https://portal.azure.com/#@$(az account show --query "tenantId" -o tsv)/resource$containerGroupId
- WebSite: http://$containerGroupFqdn

EOF

SECONDS=0 

header "Polling container group" \
	&& timeout $timeout bash -c "waitForWebServer $containerGroupFqdn $containerGroupId" \
	&& echo -e "\nWebServer starts responding after $SECONDS seconds - we are done" \
	|| echo -e "\n\nWebServer NOT responding after $SECONDS seconds - giving up"

header "Stopping container group" \
	&& echo -e "\nWe stop the container group but keep it alive to do some post mortem analasis" \
	&& az container stop --resource-group $resourcegroup --name $containerGroupName -o none 
