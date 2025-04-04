set dotenv-load

# Install cross-platform tools
build-setup:
    docker run --privileged --rm tonistiigi/binfmt --install all

# init dotenv file
init-dotenv:
    echo "C8Y_HOST=$C8Y_HOST" > .env
    c8y microservices getBootstrapUser --id devicecert | c8y template execute --template "std.join('\n', ['C8Y_BOOTSTRAP_TENANT=' + input.value.tenant, 'C8Y_BOOTSTRAP_USER=' + input.value.name, 'C8Y_BOOTSTRAP_PASSWORD=' + input.value.password])" >> .env

# register application for local development
register:
    c8y microservices create --file ./cumulocity.devicecert.json
    [ ! -f .env ] just init-dotenv

# Start local service
start:
    go run ./cmd/main/main.go

# Build microservice
build: build-setup
    goreleaser release --snapshot --clean
    ./build/microservice.sh pack --name devicecert --manifest cumulocity.devicecert.json --dockerfile Dockerfile

# Deploy microservice
deploy:
    c8y microservices create --file ./devicecert.zip

# Build client packages (to be deployed to the devices)
build-clients:
    cd clients/c8y-devicecert-renewer && nfpm package -p deb -t ../../
    cd clients/c8y-devicecert-renewer && nfpm package -p rpm -t ../../
