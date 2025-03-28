#!/bin/bash

source /etc/profile

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/..";
DEFAULT_LOG_FILE=$DIR/var/log/zerossl/zerossl.log-$(date '+%s')
KEYS_DIR="$DIR/var/lib/jelastic/keys/"
SETTINGS="$DIR/opt/letsencrypt/settings"
DOMAIN_SEP=" -d "
GENERAL_RESULT_ERROR=21
TOO_MANY_CERTS=22
WRONG_WEBROOT_ERROR=25
UPLOAD_CERTS_ERROR=26
TIME_OUT_ERROR=27
NO_VALID_IP_ADDRESSES=28
ZEROSSL_TIMEOUT_ERROR=29
ZEROSSL_SIGN_FAILED=30

counter=1

#Set maximum loop time to try 4 times in timeout situations
maxcounter=5

[ -f "${SETTINGS}" ] && source "${SETTINGS}" || { echo "No settings available" ; exit 3 ; }
[ -f "${DIR}/root/validation.sh" ] && source "${DIR}/root/validation.sh" || { echo "No validation library available" ; exit 3 ; }

#To be sure that r/w access
mkdir -p /etc/letsencrypt/
#chown -R jelastic:jelastic /etc/letsencrypt/

cd "${DIR}/opt/letsencrypt"

PROXY_PORT=12345
LE_PORT=12346

#Parameters for test certificates
test_params='';
[ "$test" == "true" -o "$1" == "fake" ] && { test_params=' --test '; }

params='';
[[ ${webroot} == "true" && -z "$webrootPath" ]] && {
    [[ ! -z ${WEBROOT} ]] && { webrootPath="${WEBROOT}/ROOT/"; } || { echo "Webroot path is not set"; exit 3; }
}
[[ "$webroot" == "true" && ! -z "$webrootPath" ]] && { params="--webroot ${webrootPath}"; } || { params=" --standalone --httpport ${LE_PORT} "; }

#format domains list according to acme client
domain=$(echo $domain | sed -r 's/\s+/ -d /g');
skipped_domains=$(echo $skipped_domains | sed -r 's/\s+/ -d /g');

[[ ! -z "$skipped_domains" ]] && {
  [[ -z "$domain" ]] && domain=$skipped_domains || domain+=" -d "$skipped_domains;
}
[[ -z "$domain" ]] && domain=$appdomain;

#Kill hanged certificate requests
killall -9 tinyproxy > /dev/null 2>&1

mkdir -p $DIR/var/log/zerossl

[[ "$webroot" == "false" ]] && {
    service tinyproxy start || { echo "Failed to start proxy server" ; exit 3 ; }

 if grep -a 'AlmaLinux' /etc/system-release ; then
    /usr/sbin/nft insert rule ip filter INPUT tcp dport ${PROXY_PORT} counter accept comment "LE"
    /usr/sbin/nft insert rule ip filter INPUT tcp dport ${LE_PORT} counter accept comment "LE"
    /usr/sbin/nft insert rule ip6 filter INPUT tcp dport ${LE_PORT} counter accept comment "LE"
    /usr/sbin/nft insert rule ip nat PREROUTING ip saddr != 127.0.0.1 tcp dport 80 counter redirect to ${PROXY_PORT} comment "LE"
    /usr/sbin/nft insert rule ip6 nat PREROUTING ip6 saddr ::0 ip6 daddr ::0 tcp dport 80 counter redirect to ${LE_PORT} comment "LE" || \
        /usr/sbin/nft insert rule ip6 filter INPUT tcp dport 80 counter drop comment "LE"
 else
    iptables -I INPUT -p tcp -m tcp --dport ${PROXY_PORT} -j ACCEPT
    iptables -I INPUT -p tcp -m tcp --dport ${LE_PORT} -j ACCEPT
    ip6tables -I INPUT -p tcp -m tcp --dport ${LE_PORT} -j ACCEPT
    iptables -t nat -I PREROUTING -p tcp -m tcp ! -s 127.0.0.1/32 --dport 80 -j REDIRECT --to-ports ${PROXY_PORT}
    ip6tables -t nat -I PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports ${LE_PORT} || ip6tables -I INPUT -p tcp -m tcp --dport 80 -j DROP
 fi
}

# setup default result_code
result_code=$GENERAL_RESULT_ERROR;

# setup default logfile
LOG_FILE=$DEFAULT_LOG_FILE"-"$counter
DEBUG_FILE=$DEFAULT_LOG_FILE"-debug-"$counter

echo "Starting log - initialized only: " > $DEBUG_FILE

##############################################################################################################################################################
##  main loop for ssl certificate
##############################################################################################################################################################

while [ "$result_code" != "0" ]
do
  [[ -z $domain ]] && break;

  if [ "$counter" -ge "$maxcounter" ]; then
    zerossl_timeout=true;
    break; 
  fi

  # setup logfile
  LOG_FILE=$DEFAULT_LOG_FILE"-"$counter
  DEBUG_FILE=$DEFAULT_LOG_FILE"-debug-"$counter
  
  echo "Starting log - ready to issue: " > $DEBUG_FILE
  
  echo "CALL:  $DIR/opt/letsencrypt/acme.sh --server zerossl --issue $params $test_params --domain $domain --nocron -f --log-level 2 --log $LOG_FILE 2>&1 " >> $DEBUG_FILE

  # remove --listen-v6  for now to test issue with blocking logs
  resp=$($DIR/opt/letsencrypt/acme.sh --server zerossl --issue $params $test_params --domain $domain --nocron -f --log-level 2 --log $LOG_FILE 2>&1)

  # find result flag
  grep -q 'Cert success' $LOG_FILE && grep -q "BEGIN CERTIFICATE" $LOG_FILE && result_code=0 || result_code=$GENERAL_RESULT_ERROR

  # log result code
  echo "result_code 1: $result_code" >> $DEBUG_FILE

  [[ "$result_code" == "$GENERAL_RESULT_ERROR" ]] && {
    error=$(sed -rn 's/.*\s(.*)(DNS problem: .*?)",\"status.*/\2/p' $LOG_FILE | sed '$!d')
    [[ ! -z $error ]] && invalid_domain=$(echo $error | sed -rn 's/.* (.*) - .*/\1/p')

    [[ -z $error ]] && {
      error=$(sed -rn 's/.*\s(.*)(Invalid response from https?:\/\/.*).*/\2/p' $LOG_FILE | sed '$!d')
      [[ ! -z $error ]] && invalid_domain=$(echo $error | sed -rn 's|(.+)addressesResolved|\1|p' | sed -rn 's|(.+)hostname.*|\1|p' | sed -rn 's|.*hostname\"\:\"([^\"]*).*|\1|p')
      [[ -z $invalid_domain ]] && invalid_domain=$(echo $error | sed -rn 's|(.+)addressesResolved|\1|p' | sed -rn 's|.*hostname\":\"(.*)|\1|p' | sed -rn 's|\",.*||p')
    }

    [[ -z $error ]] && {
      error=$(sed -rn 's/.*\s(.*)(Verify error:)/\1/p' $LOG_FILE | sed '$!d')
      [[ ! -z $error ]] && invalid_domain=$(echo $error | sed  "s/:.*//")
    }

    [[ -z $error ]] && {
      error=$(sed -rn 's/.*(Cannot issue for .*)",/\1/p' $LOG_FILE | sed '$!d')
      invalid_domain=$(echo $error | sed -rn 's/Cannot issue for \\\"(.*)\\\":.*/\1/p')
    }
    
    [[ -z $error ]] && {
      error=$(sed -rn 's/.*\s(.*)(Fetching https?:\/\/.*): Error getting validation data.*/\2/p' $LOG_FILE | sed '$!d')
      invalid_domain=$(echo $error | sed -rn 's/Fetching https?:\/\/(.*)\/.well-known.*/\1/p')
    }

    [[ -z $error ]] && {
      error=$(sed -rn 's|.*"detail":"(No valid IP addresses found [^"]+)".*|\1|p' $LOG_FILE | sed '$!d')
      [[ -z $error ]] && {
          error=$(sed -rn 's|.*"detail":"(no valid A records found for [^;]+).*|\1|p' $LOG_FILE | sed '$!d')
      }
      invalid_domain=$(echo $error | sed -rn 's/.*for (.*)/\1/p')
      [[ ! -z $error ]] && no_valid_ip=true
    }

    [[ -z $error ]] && {
      error=$(sed -rn 's/.*(Error creating new order \:\: )(.*)\"\,/\2/p' $LOG_FILE | sed '$!d');
      [[ ! -z $error ]] && {
        rate_limit_exceeded=true;
        break;
      }
    }

    # Sign failed, finalize code is not 200.  -  ZeroSSL could not validate domain 
    [[ -z $error ]] && {
      error=$(sed -rn 's/.*(Sign failed, finalize code is not 200.)/\1/p' $LOG_FILE | sed '$!d')
      [[ ! -z $error ]] && {
        sign_failed=true;
        break;
      }
    }   

    all_invalid_domains_errors+=$error";"
    all_invalid_domains+=$invalid_domain" "

    domain=$(echo $domain | sed 's/'${invalid_domain}'\(\s-d\s\)\?//')
    domain=$(echo $domain | sed "s/\s-d$//")
  }
  counter=$((counter + 1))
done

all_invalid_domains_errors=${all_invalid_domains_errors%?}

[[ ! -z $all_invalid_domains ]] && {
  all_invalid_domains=$(echo $all_invalid_domains | sed -r "s/\s-d//g")
  sed -i "s|skipped_domains=.*|skipped_domains='${all_invalid_domains}'|g" ${SETTINGS}
}
domain=$(echo $domain | sed -r "s/\s-d//g");
sed -i "s|^domain=.*|domain='${domain}'|g" ${SETTINGS};

[[ "$webroot" == "false" ]] && {
 if grep -a 'AlmaLinux' /etc/system-release ; then
    for _family in ip ip6; do
        for _table in 'filter INPUT' 'nat PREROUTING'; do
            for handle in $(nft -a list table $_family ${_table/ *} | grep 'comment \"LE\"'| sed -r 's/.*#\s+handle\s+([0-9]+)/\1/g' 2>/dev/null); do
                /usr/sbin/nft delete rule $_family $_table handle $handle;
            done
        done
    done
 else
    iptables -t nat -D PREROUTING -p tcp -m tcp ! -s 127.0.0.1/32 --dport 80 -j REDIRECT --to-ports ${PROXY_PORT}
    ip6tables -t nat -D PREROUTING -p tcp -m tcp --dport 80 -j REDIRECT --to-ports ${LE_PORT} || ip6tables -I INPUT -p tcp -m tcp --dport 80 -j ACCEPT
    iptables -D INPUT -p tcp -m tcp --dport ${PROXY_PORT} -j ACCEPT
    iptables -D INPUT -p tcp -m tcp --dport ${LE_PORT} -j ACCEPT
    ip6tables -D INPUT -p tcp -m tcp --dport ${LE_PORT} -j ACCEPT
 fi
    service tinyproxy stop || echo "Failed to stop proxy server"
    chkconfig tinyproxy off
}

if [ "$result_code" != "0" ]; then
    [[ $resp == *"does not exist or is not a directory"* ]] && invalid_webroot_dir=true
    [[ $resp == *"Read timed out"* ]] && timed_out=true
fi

#####################################################

# setup handler to exit if zerssl gets into a loop during certificate validation 
echo "checking for zerossl_timeout error" >> $DEBUG_FILE
[[ $zerossl_timeout == true ]] && exit $ZEROSSL_TIMEOUT_ERROR;

# handle signing process failed in ZeroSSL
echo "checking for sign_failed" >> $DEBUG_FILE
[[ $sign_failed == true ]] && exit $ZEROSSL_SIGN_FAILED;

# handle error exit cases
echo "checking for invalid_webroot_dir" >> $DEBUG_FILE
[[ $invalid_webroot_dir == true ]] && exit $WRONG_WEBROOT_ERROR;

echo "checking for timed_out" >> $DEBUG_FILE
[[ $timed_out == true ]] && exit $TIME_OUT_ERROR;

echo "checking for no_valid_ip" >> $DEBUG_FILE
[[ $no_valid_ip == true ]] && { echo "$error"; exit $NO_VALID_IP_ADDRESSES; }

echo "checking for rate_limit_exceeded" >> $DEBUG_FILE
[[ $rate_limit_exceeded == true ]] && { echo "$error"; exit $TOO_MANY_CERTS; }

echo "checking for bad result_code" >> $DEBUG_FILE
[[ $result_code != "0" ]] && { echo "$all_invalid_domains_errors"; exit $GENERAL_RESULT_ERROR; }


#####################################################
echo "ok to process " >> $DEBUG_FILE

#To be sure that r/w access
mkdir -p /tmp/
chmod -R 777 /tmp/
appdomain=$(cut -d"." -f2- <<< $appdomain)

#find using old path format
echo "checking certspath format 1" >> $DEBUG_FILE
certspath=$(sed -n 's/.*][[:space:][:digit:]{4}[:space:]]Your[[:space:]]cert[[:space:]]is[[:space:]]in[[:space:]]\{2\}\(.*\)./\1/p' $LOG_FILE)
echo "test certspath 1: $certspath" >> $DEBUG_FILE

#otherwise find using new acme 3.x.x format

if [ -z "$certspath" ]
then
    echo "checking certspath format 2" >> $DEBUG_FILE
    certspath=$(sed -n -e 's/^.*'[[:space:]]Your[[:space:]]cert[[:space:]]is[[:space:]]in\:[[:space:]]'//p' $LOG_FILE)
    echo "test certspath 2: $certspath" >> $DEBUG_FILE
fi

certdir=$(echo $certspath | sed 's/[^\/]*\.cer$//' | tail -n 1)
certname=$(echo $certspath | sed 's/.*\///' | tail -n 1)
certdomain=$(echo $certspath | sed 's/.*\///' | sed 's/\.cer$//')

echo "primarydomain:  $primarydomain " >> $DEBUG_FILE
echo "appdomain:  $appdomain " >> $DEBUG_FILE
echo "KEYS_DIR:   $KEYS_DIR" >> $DEBUG_FILE
echo "certspath:  $certspath" >> $DEBUG_FILE
echo "certdir:    $certdir" >> $DEBUG_FILE
echo "certname:   $certname" >> $DEBUG_FILE
echo "certdomain: $certdomain" >> $DEBUG_FILE

mkdir -p $KEYS_DIR

[ ! -z $certdir ] && {
  cp -f $certdir/* $KEYS_DIR && chown jelastic -R $KEYS_DIR
  cp -f ${certdir}/${certdomain}.key $KEYS_DIR/privkey.pem
  cp -f ${certdir}/${certdomain}.cer $KEYS_DIR/cert.pem
  cp -f ${certdir}/fullchain.cer $KEYS_DIR/fullchain.pem
}

function uploadCerts() {
    local certdir="$1"
    echo appid = $appid
    echo appdomain = $appdomain

    #Upload 3 certificate files
    uploadresult=$(curl -F "appid=$appid" -F "fid=privkey.pem" -F "file=@${certdir}/${certdomain}.key" -F "fid=fullchain.pem" -F "file=@${certdir}/ca.cer" -F "fid=cert.pem" -F "file=@${certdir}/${certdomain}.cer" http://$primarydomain/xssu/rest/upload)
    result_code=$?;

    echo "get uploadresult: $uploadresult" >> $DEBUG_FILE
    echo "get result_code: $result_code" >> $DEBUG_FILE
    
    [[ $result_code != 0 ]] && { 
        echo "$uploadresult"
        exit $UPLOAD_CERTS_ERROR 
      }

    echo "saving urls to certificate files " >> $DEBUG_FILE
    
    #Save urls to certificate files
    echo $uploadresult | awk -F '{"file":"' '{print $2}' | awk -F ":\"" '{print $1}' | sed 's/","name"//g' > /tmp/privkey.url
    echo $uploadresult | awk -F '{"file":"' '{print $3}' | awk -F ":\"" '{print $1}' | sed 's/","name"//g' > /tmp/fullchain.url
    echo $uploadresult | awk -F '{"file":"' '{print $4}' | awk -F ":\"" '{print $1}' | sed 's/","name"//g' > /tmp/cert.url

    echo "file save complete " >> $DEBUG_FILE

    sed -i '/^\s*$/d' /tmp/*.url
    exit 0;
}

while [[ "$1" != "" ]]; do
    case "$1" in
        -n|--no-upload-certs )
            shift;
            exit 0;
            ;;
    esac
    shift
done

echo "ready to uploadCerts: $certdir" >> $DEBUG_FILE

uploadCerts $certdir;

#[ "$withExtIp" == "true" ] && { uploadCerts $certdir; }
