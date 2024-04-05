OctoMesh is a powerful tool designed to seamlessly transform raw data into meaningful information, all while ensuring that the data is imbued with the context it needs to be truly insightful. Whether you're working with structured data, unstructured data, or anything in between, OctoMesh empowers you to harness the full potential of your data.

This repository contains tools to simplify the development and deployment of OctoMesh. It includes a PowerShell profile to simplify the development process and a set of scripts to manage the infrastructure with docker-compose.

# Getting started

Have a look to the [docs](http://localhost:3000/docs/developerGuide/gettingStarted/intro) to get started with OctoMesh.

The complete documentation of OctoMesh is available at https://docs.meshmakers.cloud.

# Customizing Windows Terminal Profile

1. Create Environment Variable MESHMAKERS with path to the OctoMesh repository.
2. In Windows add a new Profile and set the following settings in json:

**Terminal Profile:**

```json
{
  "altGrAliasing": true,
  "antialiasingMode": "grayscale",
  "backgroundImage": "%MESHMAKERS%\\octo-tools\\assets\\Logo_schwarz.png",
  "backgroundImageAlignment": "center",
  "backgroundImageOpacity": 0.3,
  "backgroundImageStretchMode": "fill",
  "closeOnExit": "automatic",
  "colorScheme": "Meshmakers",
  "commandline": "pwsh.exe -NoExit -ExecutionPolicy Bypass -Command . '%MESHMAKERS%\\octo-tools\\modules\\profile.ps1'",
  "cursorShape": "bar",
  "guid": "{df3c5fa9-c722-465c-b399-0ffc8bd1ba96}",
  "hidden": false,
  "historySize": 90001,
  "icon": "%MESHMAKERS%\\octo-tools\\assets\\meshmakers64.png",
  "name": "MeshConsole",
  "padding": "8, 8, 8, 8",
  "snapOnInput": true,
  "startingDirectory": "%MESHMAKERS%",
  "useAcrylic": true
}
```

**Color Scheme:**

```json
{
  "background": "#3A695C",
  "black": "#0C0C0C",
  "blue": "#0037DA",
  "brightBlack": "#767676",
  "brightBlue": "#3B78FF",
  "brightCyan": "#61D6D6",
  "brightGreen": "#16C60C",
  "brightPurple": "#B4009E",
  "brightRed": "#E74856",
  "brightWhite": "#F2F2F2",
  "brightYellow": "#F9F1A5",
  "cursorColor": "#FFFFFF",
  "cyan": "#3A96DD",
  "foreground": "#FFFFFF",
  "green": "#13A10E",
  "name": "Meshmakers",
  "purple": "#881798",
  "red": "#C50F1F",
  "selectionBackground": "#FFFFFF",
  "white": "#CCCCCC",
  "yellow": "#C19C00"
}
```

3. Further customization:

create a folder in the users directory: `.pwsh` and add a `profile.ps1`
This gets loaded when the terminal starts. You can for example disable the octo promt (`OCTO >`) by disabling `$Global:WantPromt = $true` in your custom `profile.ps1`.

# Support and Feedback

If you encounter any issues or have questions while using OctoMesh, please don't hesitate to reach out to our support team at support@meshmakers.io. We value your feedback and are committed to helping you make the most of OctoMesh.

# License

OctoMesh is released under the MIT License. Feel free to use and modify it according to your needs, and we encourage contributions from the community to enhance the system further.

Thank you for choosing DTS as your data transformation solution. We look forward to seeing how it empowers you to turn data into valuable insights.

Happy transforming! 🚀
