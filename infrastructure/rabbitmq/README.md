# Local RabbitMQ definitions (AB#7338, B0a)

`definitions.json` is loaded by the local broker (docker-compose service `rabbitmq` and the kind Deployment
`octo-infra/rabbitmq`, `Install-OctoKubernetes` puts it into the ConfigMap `rabbitmq-definitions`).

| User | Password | Tags | Permissions on `/` |
|---|---|---|---|
| `guest` | `guest` | administrator | `.*` `.*` `.*` (as before; the host services and the core services use it) |
| `octo-adapter-mq-user` | `adapter` | none | everything except resources whose name contains `octo::method::` (CK method queues/exchanges), and no write to `amq.default` |

The adapter user mirrors what meshmakers-infrastructure deploys to the clusters (`rabbitmq_adapter_user_defaults`, runbook
`docs/runbooks/rabbitmq-adapter-user.md` in that repo) so a local adapter can be started with the restricted credentials
and a regression shows up before a cluster. Both passwords are local development credentials; the password hashes are
salted SHA-256 with a fixed salt (the file is stable in git). Change the hash with:

```bash
python3 -I -c 'import base64,hashlib,sys; s=bytes.fromhex("0c7a5e21"); print(base64.b64encode(s+hashlib.sha256(s+sys.argv[1].encode()).digest()).decode())' adapter
```

Check the running local broker (no password of a cluster is involved): `infrastructure/scripts/verify-adapter-broker-user.sh`.
