#!/bin/bash
# custom-code.sh
#
# This file holds ONLY the custom/extra logic that should run at the very end
# of the IDE bootstrap process, after code-server, Caddy, Docker, etc. have
# already been installed and configured.
#
# In the original CloudFormation template this was the "customBootstrapScript"
# value (Fn::Sub: "touch /tmp/temporary.hello"). It is kept as its own file
# here so it can be edited independently of the main setup script.
#
# Its contents are read with Terraform's file() function and injected into
# scripts/setup-vscode-server.sh.tftpl at the "${custom_bootstrap_script}"
# placeholder.
#
# Add whatever custom provisioning you need below.

touch /tmp/temporary.hello
