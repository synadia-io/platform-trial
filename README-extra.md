If you are interested in trying out Synadia Platform against an existing NATS system, check out the [installation guide](https://docs.synadia.com/platform/install) for more information.

## Setting up HTTP Gateway

It is implemented as a standalone component and that requires a pre-configured KV bucket for retrieving tokens that are generated by Control Plane.

### Create the account, user, and KV bucket

Although not required, it is recommended to create a dedicated account and user for the HTTP Gateway. On the `trial` system page, go to `Accounts` and add a new account called `http-gateway`. Then add a user called `http-gateway` to the account. Click into the new user and click the drop-down `Get Connected` to download the credentials.

Copy that file to the root of this repository and rename it to `http-gateway.creds`.

Next, go to `JetStream` and create a new KV bucket called `http-gateway` with the default settings.

### Start the HTTP Gateway

In a separate terminal, run the following command to bring up the HTTP Gateway:

```bash
docker compose up http-gateway
```

```
  http-gateway:
    image: registry.synadia.io/http-gateway:latest
    environment:
      NHG_PORT: "8080"
      NHG_URL: "nats://nats1:4222,nats://nats2:4222,nats://nats3:4222"
      NHG_TOKENS_BUCKET: "http-gateway"
      NHG_PROVIDER_CREDS: "/http-gateway.creds"
      NHG_DISABLE_LOGGING: "false"
    command:
      - "run"
    volumes:
      - ./http-gateway.creds:/http-gateway.creds

```