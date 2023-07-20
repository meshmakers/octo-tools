# Configure MongoDB

After configuring MongoDB, make sure that it is already active when starting the project.

## Create key file

First, a key file is needed for authentication with Mongodb replicator sets.

### Debian bullseye

Create the key and configure mod and owner

```shell
cd ~/Development/meshmakers/octo_utils
```

```shell
openssl rand -base64 756 > mongodb_keyfile
```

```shell
sudo chmod 400 mongodb_keyfile
```

```shell
sudo chown mongodb:mongodb mongodb_keyfile
```

## Add admin user

To add an admin user, run the script `create-users.ps1` or run the following command.

```shell
mongosh mongodb://localhost:27017/admin samples/createAdminUser.js
```

## Configuration

Go to the config file and adjust the following entries.

```
security:
  authorization: enabled
  keyFile: /path/to/the/key/file

replication:
  replSetName: rs0
```

The config file can be found under the following paths.

| OS              | PATH               |
|-----------------|--------------------|
| Debian bullseye | `/etc/mongod.conf` |

Restart the DB and then connect as admin.

```shell
mongosh mongodb://osp-system-admin:OspAdmin1@localhost:27017/?authSource=admin
```

The configuration is completed with the initialisation of the cluster.

```shell
rs.initiate()
```
