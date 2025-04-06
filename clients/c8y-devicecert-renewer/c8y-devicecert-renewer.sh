#!/bin/sh
set -e
#
# Try to renew the certificate, but assume the script can
# be killed at any point in time so backup the certificate before
# replacing it, and validate the new certificate and rollback to the
# previous certificate on failure.
#
# Key design points:
# * don't assume the current certificate is loaded by the bridge
# * if a backup exists, then the renewal process was interrupted
# * remove any backups after the new certificate has been verified
#
usage() {
    cat <<EOT
Reliable certificate renewer to check if a certificate should be renewed
and to renew the certificate in a reliable manner by backing up the previous
certificate, and rolling back if the new certificate does not pass the validation
check.

The scripts relies on the Cumulocity certificate-authority feature to work.

Usage

  $0 needs-renewal <cloud>      Check if the certificate needs renewal (exit code 0 if it does)
  $0 renew <cloud>              Renew the certificate for the given cloud

Examples

$0 needs-renewal c8y 
# Check if the Cumulocity certificate needs renewal

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
BACKUP_CERTIFICATE="${CERT_PATH}.bak"
RENEW_TYPE=${RENEW_TYPE:-c8y-self-signed}

# MQTT topics
TOPIC_ROOT=$(tedge config get mqtt.topic_root)
TOPIC_ID=$(tedge config get mqtt.device_topic_id)
DEVICE_TOPIC="${TOPIC_ROOT}/${TOPIC_ID}/a/certificate"

# Only used for tedge < 1.5.0 where openssl is used to check if the cert is about to expire
# Newer tedge versions have a customizable tedge.toml value to control this instead
OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC="${OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC:-}"
if [ -z "$OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC" ]; then
    OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC=$((90 * 86400))
fi

#
# Helpers
#
verify_certificate_or_rollback() {
    if tedge reconnect "$CLOUD"; then
        echo "Successfully reconnected to $CLOUD. Removing backup certificate" >&2
        rm -f "$BACKUP_CERTIFICATE"
        return
    fi

    # rollback
    echo "Failed to connect to ${CLOUD}, restoring last known working certificate"
    echo "------ BEGIN Failed Certificate ------" >&2 ||:
    head -n 100 "$CERT_PATH" >&2 ||:
    echo "------ END Failed Certificate ------" >&2 ||:
    restore_backup
    tedge reconnect "$CLOUD" || echo "WARNING: Failed to reconnect after restoring previous certificate. Maybe it is just an transient error" >&2
}

is_backup_same() {
    # Note: if the cmp command does not exist, then it will fail which 
    # means it will assume the files are not the same (which is more defensive)
    cmp -s "$BACKUP_CERTIFICATE" "$CERT_PATH"
}

#
# Commands
#
needs_renewal() {
    if [ -f "$BACKUP_CERTIFICATE" ]; then
        echo "Found a left-over certificate backup file which is a sign that the renewal did not fully complete" >&2
        exit 0
    fi

    # Check if certificate expires soon (newer tedge versions have a command for this, but fallback to using openssl)
    if /usr/bin/tedge cert needs-renewal --help >/dev/null 2>&1; then
        echo "Checking validity using tedge" >&2
        /usr/bin/tedge cert needs-renewal "$CLOUD"
    elif command -V openssl >/dev/null 2>&1; then
        echo "Checking validity using openssl" >&2
        if [ ! -f "$CERT_PATH" ]; then
            echo "Certificate does not exist. path=$CERT_PATH" >&2
            exit 1
        fi

        if ! openssl x509 -checkend "$OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC" -noout -in "$CERT_PATH"; then
            echo "Certificate will expire soon (within ${OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC}s)" >&2
            # certificate will expire
            exit 0
        else
            echo "Certificate does not expire soon. min_duration=${OPENSSL_MIN_CERT_VALIDITY_DURATION_SEC}s" >&2
            exit 1
        fi
    else
        echo "No tool found to check the certificate's validity. Neither 'tedge cert needs-renewal' nor 'openssl' is installed on the device" >&2
        exit 1
    fi
}

create_alarm() {
    # Create an alarm 
    BODY=$(
        cat <<EOT
{
  "text": "Self-signed certificate renewal failed",
  "severity": "major"
} 
EOT
)
    tedge mqtt pub -r "$DEVICE_TOPIC" "$BODY"
}

clear_alarm() {
    tedge mqtt pub -r "$DEVICE_TOPIC" ""
}

renew_self_signed() {
    #
    # Renew using a Cumulocity trusted-certificate proxy microservice
    #
    if tedge cert renew --self-signed --help >/dev/null 2>&1; then
        if ! tedge cert renew --self-signed; then
            return 1
        fi
    else
        if ! tedge cert renew; then
            return 1
        fi
    fi

    MICROSERVICE_URL="/c8y/service/devicecert/certificates/upload"
    if tedge http --help >/dev/null 2>&1; then
        tedge http post "$MICROSERVICE_URL" --file "$(tedge config get "${CLOUD}.device.cert_path")"
    else
        curl -f -XPOST "http://$(tedge config get c8y.proxy.client.host):$(tedge config get c8y.proxy.client.port)$MICROSERVICE_URL" --data-binary @"$(tedge config get "${CLOUD}.device.cert_path")"
    fi 
}

renew_cert() {
    #
    # Extendable cert renewal (allowing other processes to provide the certificate)
    #
    case "$RENEW_TYPE" in
        c8y-self-signed)
            echo "Renewing self-signed certificate using the c8y-devicecert microservice" >&2
            renew_self_signed
            ;;
        c8y-ca|*)
            echo "Trying to renew using the Cumulocity certificate-authority" >&2
            tedge cert renew "$CLOUD"
            ;;
    esac
}

restore_backup() {
    chmod 644 "$CERT_PATH"
    mv "$BACKUP_CERTIFICATE" "$CERT_PATH"
    chmod 444 "$CERT_PATH"
}

renew() {
    # If a backup file already exists, than the script may of been interrupted, so check if the
    # current connection is ok or not, and revert to the backup if necessary
    # If we don't do this check, then it could result in the backup replacing a potentially good certificate
    if [ -f "$BACKUP_CERTIFICATE" ]; then
        if is_backup_same; then
            echo "Back file is the same so removing it" >&2
            rm -f "$BACKUP_CERTIFICATE"
        else
            echo "Warning: backup certificate exists and is different to current file. path=$BACKUP_CERTIFICATE" >&2
            verify_certificate_or_rollback
        fi
    fi

    echo "Backup up certificate file. $BACKUP_CERTIFICATE" >&2
    cp "$CERT_PATH" "$BACKUP_CERTIFICATE"

    if ! renew_cert; then
        echo "Certificate renewal failed. Cleaning up backup" >&2
        create_alarm || echo "Failed to create alarm" >&2

        # Check if the existing certificate has been overwritten by
        # the renew command, if so, then the backup should be restored
        if is_backup_same; then
            echo "Certificate and backup are the same file so removing the backup" >&2
            rm -f "$BACKUP_CERTIFICATE"
        else
            echo "Certificate has been changed by the renewal process even though it was not successful, so restoring the backup" >&2
            restore_backup
        fi

        echo "Failed to renew certificate" >&2
        exit 1
    fi

    verify_certificate_or_rollback
    clear_alarm || echo "Failed to clear alarm" >&2
}

#
# Main
#
case "$COMMAND" in
    needs-renewal)
        needs_renewal
        ;;
    renew)
        renew
        ;;
    *)
        echo "ERROR: Unknown subcommand. $COMMAND" >&2
        usage
        exit 1
        ;;
esac
