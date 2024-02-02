# Configure GIT

The project is available under https://github.com/meshmakers/. 
Details on cloning via SSH should be displayed there.

## Enable git clone via ssh

To be able to clone via ssh from dev.azure.com, the configuration must be adapted.</br>
Add the following lines to `~/.ssh/conf`:

```
Host ssh.dev.azure.com
    User git
    IdentityFile ~/.ssh/private_key
    HostkeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
```

**Replace `private_key` with the name of the key file.**

### Use password manager

If you are using a password manager like 1password, there is maybe a integrated solution to handle keys in a more secure way. 

In this case a sample how it works in 1password.

- Create a new SSH key in 1password 
- Use RSA key as type
- Start SSH agent as documented at https://developer.1password.com/docs/ssh/agent/#:~:text=The%201Password%20SSH%20agent%20uses,even%20leaves%20the%201Password%20app.
- Don't forget to execute steps at https://developer.1password.com/docs/ssh/get-started/#step-4-configure-your-ssh-or-git-client to configure git to use SSH agent


