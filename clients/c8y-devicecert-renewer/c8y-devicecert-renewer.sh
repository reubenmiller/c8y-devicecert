#!/bin/sh
set -e
#
# Custom certificate renewal script.
#
usage() {
    cat <<EOT
Renew a self-signed certificate by using the custom c8y-devicecert microservice

Note: This is only intended to be used in environments where the Cumulocity
Certificate Authority feature is not yet available, and users need a solution
until the feature is available. Afterwards, the service should be removed and
replaced by the in-built thin-edge.io tedge-cert-renewer@c8y service.

Usage

  $0 renew <cloud>              Renew the certificate for the given cloud

Examples

$0 renew c8y
# Renew the Cumulocity certificate

EOT
}

if [ $# -lt 2 ]; then
    echo "ERROR: missing required positional arguments" >&2
    usage
    exit 1
fi

COMMAND="$1"
CLOUD="$2"
shift
shift

CERT_PATH=$(tedge config get "${CLOUD}.device.cert_path")
NEXT_CERTIFICATE="${CERT_PATH}.new"
# Either: 'self-signed' or 'c8y'
RENEW_WITH_CA=${RENEW_WITH_CA:-self-signed}

# MQTT topics
TOPIC_ROOT=$(tedge config get mqtt.topic_root)
TOPIC_ID=$(tedge config get mqtt.device_topic_id)
DEVICE_TOPIC="${TOPIC_ROOT}/${TOPIC_ID}/a/certificate"


#
# Commands
#
create_alarm() {
    # Create an alarm 
    BODY=$(
        cat <<EOT
{
  "text": "certificate renewal failed",
  "ca": "$RENEW_WITH_CA",
  "severity": "major"
} 
EOT
)
    tedge mqtt pub -r "$DEVICE_TOPIC" "$BODY" || echo "Failed to create alarm" >&2
}

clear_alarm() {
    tedge mqtt pub -r "$DEVICE_TOPIC" "" || echo "Failed to clear alarm" >&2
}

renew() {
    if ! tedge cert renew "$CLOUD" --ca "$RENEW_WITH_CA"; then
        create_alarm
        echo "Failed to renew certificate" >&2
        exit 1
    fi

    case "$RENEW_WITH_CA" in
        self-signed)
            # self-signed has an additional step which is required
            echo "Uploading self-signed certificate using the c8y-devicecert microservice" >&2
            if ! tedge http post "/c8y/service/devicecert/certificates/upload" --file "$NEXT_CERTIFICATE"; then
                echo "Failed to upload self-signed certificate" >&2
                create_alarm
                exit 1
            fi
            ;;
    esac

    clear_alarm
}

#
# Main
#
case "$COMMAND" in
    renew)
        renew
        ;;
    *)
        echo "ERROR: Unknown subcommand. $COMMAND" >&2
        usage
        exit 1
        ;;
esac
