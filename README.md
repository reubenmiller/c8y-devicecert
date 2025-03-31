# Introduction

Cumulocity microservice to support customers who are using thin-edge.io with self signed certificates, but can't
use the new upcoming Cumulocity Certificate Authority feature.

The microservice provides one endpoint which allows for already registered devices to upload a new self-signed certificate
using a JWT obtained from the previous certificate.

* Only devices are allowed to upload a new self-signed certificate
* Device user must match the Common Name of the certificate being added
* The previous certificate is not removed (this may change in the future)

The project uses the unofficial [github.com/reubenmiller/go-c8y](github.com/reubenmiller/go-c8y) Cumulocity client modules.

# Getting Started

## Starting the app locally

1. Clone the project

    ```sh
    git clone https://github.com/reubenmiller/c8y-devicecert.git
    cd c8y-devicecert
    ```

1. Create an application (microservice) placeholder in Cumulocity with the requiredRoles defined in the `cumulocity.devicecert.json`

    ```sh
    just register
    ```

1. Add the new user role to the device user group

    ```sh
    c8y userroles addRoleToGroup --group devices --role ROLE_SELF_SIGNED_CERT_CREATE
    ```

1. Start the application

    ```sh
    just start
    ```

1. Try uploading a self-signed certificate

    ```sh
    c8y api POST "http://localhost:8080/certificates/upload" --file "$(tedge config get device.cert_path)" --force
    ```

## Build

**Pre-requisites**

* Install `jq`. Used to extract the microservice version from the cumulocity.json
* Install `zip`. Used by microservice script to create a zip file which can be uploaded to Cumulocity

Build the Cumulocity microservice zip file by executing

```sh
just build
```

You can then deploy the microservice using:

```sh
just deploy
```

## Deployment to Cumulocity IoT

1. Activate an already created go-c8y-cli session

    ```sh
    set-session
    ```

1. Download the microservices from the releases pages

    ```sh
    wget https://github.com/reubenmiller/c8y-devicecert/releases/download/0.0.1/devicecert.zip
    ```

1. Install the microservice

    ```sh
    c8y microservices create --file ./devicecert.zip
    ```

1. Add the following user roles to be able to request new tokens

    ```sh
    c8y userroles addRoleToGroup --group devices --role ROLE_SELF_SIGNED_CERT_CREATE
    ```

On the device running thin-edge.io, you can renew the certificate using the following steps:

1. Renew the self-signed certificate

    ```sh
    tedge cert renew --self-signed
    tedge http post /c8y/service/devicecert/certificates/upload --file "$(tedge config get device.cert_path)"
    tedge reconnect c8y
    ```

1. Upload the certificate using the microservice in this repository

    ```sh
    tedge http post /c8y/service/devicecert/certificates/upload --file "$(tedge config get device.cert_path)"
    ```

1. Reconnect to Cumulocity

    ```sh
    tedge reconnect c8y
    ```
