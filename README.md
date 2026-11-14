## Run HakiOS in a Droidspaces container

This repo includes a single launcher script for a Debian Droidspaces container:

```sh
curl -fsSL https://raw.githubusercontent.com/kzeedev/hakios-xnu-kernel/main/scripts/droidspaces-qemu.sh \
  -o /usr/local/bin/hakios-qemu
chmod +x /usr/local/bin/hakios-qemu

# run as root inside the container
hakios-qemu install
hakios-qemu start
hakios-qemu status
hakios-qemu stop
