# Clone the project

The project is available
under [dev.azure.com/salzburgdev](https://dev.azure.com/salzburgdev/Internal/_git/ObjectServicePlatform).<br>
Details on cloning via HTTPS or SSH should be displayed there.

## Debian bullseye

### Enable git clone via ssh

To be able to clone via ssh from dev.azure.com, the configuration must be adapted.<br>
Add the following lines to `~/.ssh/conf`:

```
Host ssh.dev.azure.com
    User git
    IdentityFile ~/.ssh/private_key
    HostkeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

**Replace `private_key` with the name of the key file.**

### Enable private NuGet repos

Currently there are problems with the certificat provider, so this has to be enabled separately.<br>
For details please
click [here](https://rider-support.jetbrains.com/hc/en-us/community/posts/360009631420-Using-NuGet-feed-of-private-azure-devops-projects-with-oauth2-not-working)
and [here](https://github.com/microsoft/artifacts-credprovider#azure-artifacts-credential-provider).

The following command executes a script that solves the problem.

```shell
wget -qO- https://aka.ms/install-artifacts-credprovider.sh | bash
```

