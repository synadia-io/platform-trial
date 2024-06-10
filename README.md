# Synadia Platform Trial

[Synadia Platform](https://synadia.com/platform) is a bundled distribution of enterprise-grade components that augment the capabilities of [NATS.io](https://nats.io).

The current components include:

- NATS - A high-performance connectivity technology for building scalable cloud-to-edge applications.
- Control Plane - A web-based management interface for observing and monitoring NATS systems, managing NATS accounts and users, and managing, viewing, and sharing JetStream assets.
- HTTP Gateway (coming soon) - An HTTP interface for interacting with key-value buckets, object stores, and general messaging over subjects.

For this trial, the goal is to spin up an isolated stack in Docker in order to evaluate the features of the platform.

## Prerequisites

### Sign up for the trial

[Sign up here](https://synadia.com/platform/trial) if you haven't already. You will receive an email with credentials to access the Synadia image registry.

### Install Docker

If you don't have Docker installed, refer to the [Get Docker](https://docs.docker.com/get-docker/) documentation for instructions on how to install Docker Desktop or [Docker Engine](https://docs.docker.com/engine/install/) on your plaform.

### Login to the registry

Using the credentials from the previous step, login to the Synadia image registry, following the prompts.

```bash
docker login registry.synadia.io
```

### Clone this repository

The next step is to clone the `platform-trial` repository which contains the Docker Compose file and pre-defined configuration for the trial.

```bash
git clone https://github.com/synadia-io/platform-trial.git
cd platform-trial
```

## Setup Control Plane and NATS

The first component to setup is Control Plane.

### Start Control Plane

In your terminal, run the following command:

```bash
docker compose up control-plane
```

In the logs, Control Plane will generate a password for the administrative user. It will look something like this:

```
[INFO] [component:app] *****************************************************************************
[INFO] [component:app] *** Welcome to Synadia Control Plane!
[INFO] [component:app] *** An admin user has been created.
[INFO] [component:app] *** Please change the password in the Profile section after logging in.
[INFO] [component:app] *** username: admin
[INFO] [component:app] *** password: 6v69rxr6LBfSSAc82yfgKXVM3e5dp4Lz
[INFO] [component:app] *****************************************************************************
```

Copy the generated username and password for the next step.

### Login to Control Plane

Open a browser and navigate to `http://localhost:8080`. Enter the generated username and password in the previous step. You will be redirected to a page with a button `Add System` to connect your first NATS system.

Click `Add System` and enter the following information with the `Create` option chosen.

- Name: `trial`
- URL: `nats://nats1:4222,nats://nats2:4222,nats://nats3:4222`

In this example, the hostnames of the URL are the names of the NATS containers in the Docker Compose file.

Leave `Enable JetStream` checked and click `Save`. You will be redirected to the `NATS Settings` page.

### Configure NATS Settings

For `Choose a platform...`, select `Docker`. Copy the configuration contents and paste it into a new file called `shared.conf` in the root of this repository. This contains the generated operator and system account JWTs used for preloading the NATS configuration.

Click `Continue`, then under `Select NATS Connection Method`, choose `Connect Directly to NATS`.

### Start the NATS cluster

In a separate terminal, run the following command to bring up the NATS cluster:

```bash
docker compose up nats1 nats2 nats3
```

### Test the NATS connection

Back in Control Plane, click `Test Connection`. You should see a success message and click `Submit`.

## Explore Control Plane

Now that the NATS system is connected, you can explore the features of Control Plane.

TODO
