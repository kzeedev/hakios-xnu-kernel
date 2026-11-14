## Run HakiOS in a Droidspaces container (open-kernel mode)

This repo also includes a simple container launcher for the Apple-free HakiOS VM.

Use it from a Debian Droidspaces container as root:

```sh
curl -fsSL https://raw.githubusercontent.com/kzeedev/hakios-xnu-kernel/main/scripts/droidspaces-open-qemu.sh \
  -o /usr/local/bin/hakios-open-qemu
chmod +x /usr/local/bin/hakios-open-qemu

hakios-open-qemu install
hakios-open-qemu start
hakios-open-qemu status
hakios-open-qemu stop
