#!/bin/bash

# Author: Nolan Cretney
# The purpose of this script is to monitor the APIs developed by Kris Easter 
# The exit statuses indiacte problems and are suitable for nagios 

BASENAME=$(basename $0) 
if [[ $1 == '-h' || $1 == '--help' ]]; then
	cat <<EOF

USAGE: $BASENAME  -w [WARNINGTIME] -c [CRITICALTIME] -u [USER] -p [PASSWORD] -e [ENV] 

Overview:
The Purpose of this script is to make API calls to lmsmanager to see if they are up and running. This is accompished by using a serries of curl commands that logs into the lmsmanager app, getting past the authorization, then making a series of curl calls to the apis. The script looks for 200's reponse codes to confirm the apis are working as intended

Flags:
 -w  or  --warning ----> Set the warning time threshold 
 -c  or  --critical ----> Set the cricital time threshold	
 -u  or  --user ---> Set the login name
 -p  or  --password ---> Set the password
 -e  or  --environment ---> Set the environment to monitor (test/dev/prod)

Exit statuses (Nagios Plugin API):
  0  - OK
  1  - Warning (not all of apis returned with 200's)
  2  - Critical (could not finish AUTH)
  3  - Unknown (process could not finish correctly)

EOF
exit 1
fi

USER=
PASS=
WARNINGTIME=10
CRITICALTIME=20
ENV= 
MSG=

if [ $# -eq 0 ]; then
	echo "Incorrect usage, type ./$BASENAME -h or ./$BASENAME --help on how to use this script"
	exit 1
fi

 
####### process the cmd line arguments ########
while [ $# -gt 0 ] 
do
	case "$1" in
		-w ) WARNINGTIME="$2"; shift
		;;
		--warning ) WARNINGTIME="$2"; shift
		;;
		-c ) CRITICALTIME="$2"; shift
		;;
		--critical ) CRITICALTIME="$2"; shift
		;;
		-u ) USER="$2"; shift
		;;
		--user ) USER="$2"; shift
		;;
		-p ) PASS="$2"; shift
		;;
		--password ) PASS="$2"; shift
		;;
		-e ) ENV="$2"; shift
		;;
		--environment ) ENV="$2"; shift
		;;
	esac
	shift
done

#############################################
case "$ENV" in
	dev ) LMS="https://lmsmanager-dev.colorado.edu/LMSManager"; FedAuth="https://fedauth-test.colorado.edu"; 
	;;
	test ) LMS="https://lmsmanager-test.colorado.edu/LMSManager"; FedAuth="https://fedauth-test.colorado.edu";
	;;
	prod ) LMS="https://lmsmanager.colorado.edu/LMSManager"; FedAuth="https://fedauth.colorado.edu";
	;;
esac

startTime=$(date +"%s")

STATUS=0
COOKIEJAR=$(mktemp /tmp/${BASENAME}.XXXXXX) || exit 3

######################## Log in to the LMS app to get past the authorization step, save shib session #########################################

### Request 1: Get redirected to FedAuth
HTML=$(curl -L -sS -c ${COOKIEJAR} -w 'LAST_URL:%{url_effective}' ${LMS}/Fun.html) || STATUS=2 
AUTHURL=$(echo $HTML | sed -e 's/.*LAST_URL:\(.*\)$/\1/')

## Verify redirect
SIZE=${#AUTHURL}
if [[ "$SIZE" -lt 123 ]]; then
	if [[ "${AUTHURL:0:28}" != "$FedAuth" ]]; then
		MSG=${MSG:-"CRITICAL: No redirect Detected. Authorization Failed"}
		STATUS=2
	fi
else
	if [[ "${AUTHURL:0:33}" != "$FedAuth" ]]; then
		MSG=${MSG:-"CRITICAL: No redirect Detected. Authorization Failed"}
		STATUS=2
	fi
	
fi

if [[ $STATUS -eq 0 ]]; then

	### REQUEST 2: Log in
	$(curl -L -sS -c ${COOKIEJAR} -b ${COOKIEJAR} -d "j_username=$USER" -d "j_password=$PASS" -d "_eventId_proceed=submit" $AUTHURL -o html1.html) || STATUS=2

	### verify the Login was successfull
  	grep -q 'SAMLResponse' html1.html
  	if [[ $? -eq 1 ]]; then
  		STATUS=2
  	fi

  	if [[ $STATUS -eq 0 ]]; then
  		### parse the HTML output for SAML endpoint and response
  		ENDPOINT=$(grep "form action." html1.html | sed 's/.*action..//' | sed 's/\".*//' | perl -MHTML::Entities -le 'while(<>) {print decode_entities($_)}')
		SAMLRESPONSE=$(grep 'name=.SAMLResponse' html1.html | sed 's/.*value..//' | sed 's/\".*//')  		
    	RELAYSTATE=$(grep 'name=.RelayState' html1.html | sed 's/.*value..//' | sed 's/\".*//' | perl -MHTML::Entities -le 'while(<>) {print decode_entities($_);}')
  		 
  		### REQUEST 3: POST the SAMLResponse
  		$(curl -L -sS -c ${COOKIEJAR} -b ${COOKIEJAR} --data-urlencode "SAMLResponse=${SAMLRESPONSE}" --data-urlencode "RelayState=${RELAYSTATE}" -D header.txt $ENDPOINT -o html2.html) || STATUS=2


  		### VERIFY SUCCESS
  		respCode="$(grep "HTTP/1.1 200" header.txt | cut -f2 -d ' ')"
		if [[ "$respCode" != "200" ]]; then
			STATUS=2
        	MSG=${MSG:-"CRITICAL: Final HTML validation failed."}
		fi

	else
		MSG=${MSG:-"CRITICAL: POST SAMLResponse not found. Authorization Failed"}
  	fi
fi
########################################################################################################################################
rm -f header.txt
################################################## Monitor APIS ##############################################################


MANAGE="rest/ManageLMS"
CREATE="rest/CreateLMS"
CREATECMTY="rest/CreateLMS/initCommunityCourse"
ADDSEC="rest/AddSections"
BATCH="rest/BatchLMS"
BATCH2="rest/BatchLMS/process"
typeset -A TABLE

if [[ $STATUS -eq 0 ]]; then
	
	# test 1 : ManageLMS
	$(curl -L -sS -b ${COOKIEJAR} -c ${COOKIEJAR} -D header.txt ${LMS}/${MANAGE}/APPM1350/300/20164/BCS)
	respCode="$(grep 'HTTP/1.1' header.txt | cut -f2 -d ' ')"
	TABLE[ManageLMS]=$respCode
	
fi

for key in "${!TABLE[@]}"; do
	echo "$key"
done


echo $STATUS - $MSG
exit $STATUS