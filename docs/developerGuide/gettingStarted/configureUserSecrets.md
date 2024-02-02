# Configure user secrets

In the development environment, user secrets must be configured.</br>
The secrets contain passwords for the following accounts:

- Admin account (`osp-system-admin`): This account is used to create new databases.</br>
- Data source accounts (`osp-system-ds-user-{0}`): This account is created for each database.</br>
  The `{0}` is the name of the database in MongoDB.

If JetBrains Rider is used there is the plugin `.NET Core User Secrets` which simplifies the configuration. It adds the
following options under `tools` in the context menu.

- `Initialize User Secrets`
- `Open Project User Secrets`

Add the following secrets to the projects listed below:

```json
{
  "System:AdminUserPassword": "OctoAdmin1",
  "System:DatabaseUserPassword": "OctoUser1"
}
```

Project list:

- `AssetRepositoryServices`
- `IdentityServices`
- `BotServices`
- `PolicyServices`
