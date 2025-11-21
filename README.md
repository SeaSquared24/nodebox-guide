# nodebox-guide
A written guide for building a Ministry of Nodes style Nodebox from the ground up.

# Requirements

This guide assumes you have already made installation media in the form of a thumbdrive with the latest version of Debian. At the time of writing, these steps have been performed by the author on Debian Bullseye, Bookworm, and Trixie. Most, if not all, of these steps will work on the latest version of Ubuntu as well, with the only exception that comes to mind being the installation/usage of Docker which we won't be using in this setup.

You will need:
- A 16GB thumbdrive with Debian Trixie flashed to it.
- Dell Optiplex of your choice. The 9020M is very cheap and has an older i5 and 8G RAM, plenty for this project.
- Minimum 2T of SSD storage installed in the Optiplex.
- Wired Ethernet connection.
- Display with correct connection type for your chosen hardware.
- Keyboard.
- OPTIONAL: APC Backups 600

# Install Debian

Plug the thumbdrive into any of the usb ports on the Optiplex.

Power on the Optiplex and tap the F12 key until the BIOS pops up. You may need to select BIOS from a start menu. Find the power settings and set the box to return to previous power state in the event that AC power is found. For example, if you manually shutdown the box, then plug it in to a different outlet when moving it around, the box will stay off. In the event of a power failure, the box will boot up as soon as the power comes back on.

Find the boot section and change the boot order to boot from usb first. Save and Exit the BIOS. The device should now boot to the Debian Installer.

## Debian Installer

Read all of the prompts. Select your keyboard, timezone, etc as normal. At some point you'll be asked what to name the computer, call it nodebox. DO NOT activate root. Skip that one and then enter your name as satoshi and leave the username on the next page as satoshi as well. You can make the password satoshi as well for ease of finishing this guide and then change the password to something stronger when done. Do not install any non-free software, that's mostly just to get Wifi drivers working and we don't need them.

Near the end, there should be a section on Desktop Environment. Since we are doing this as a server, we won't need one. Deselect debian desktop environment, Gnome, and any other environments. Deselect SSH server. We're going to be using Cockpit instead.

To finish, it will ask how you want to do the install and you will select Use Entire Disk. Don't worry about LVM or any of the other options. Just do the normal Use Entire Disk. Wait for that to complete. 

When the installer says you can restart the machine, do so and after the lights go out, remove the thumbdrive. Debian will now boot directly into a black terminal screen with a text-based login prompt.

## Install avahi-daemon and cockpit

Login by typing satoshi as your username and whatever your password was. Bring the system up to date and install these two packages:

```
sudo apt update && sudo apt upgrade -y

sudo apt install avahi-daemon cockpit
```

## Add self-signed certificates to cockpit to encrypt your sessions when using it

```
# Make a directory to stash all our certs in.
mkdir certs

cd certs/

# Create the cert files.
openssl req -new -newkey rsa:2048 -nodes -keyout cockpit.key -out cockpit.csr

# Add those certs to cockpit config.
sudo bash -c 'cat server.crt ca.crt cockpit.key \
  > /etc/cockpit/ws-certs.d/10-internal-ca.cert'

# Reload cockpit to apply changes.
sudo systemctl restart cockpit

```

Type `exit` and hit Enter to log out.

When done, you may remove the keyboard and display and plug the box in wherever it needs to be in your house (as long as the ethernet cable can reach ;) ).

# Access nodebox via cockpit

Cockpit runs on port 9090 and avahi-daemon broadcasts the name of the device to the network so now, you can do the remaining setup in the cockpit GUI by opening your favorite browser and entering `http://nodebox.local:9090/`. Login with the same credentials as before. System information can be found all over the place and on the left hand side you will see access to the terminal so go there.

# Install Bitcoin Core using script

Open the [Install Script](/main/bitcoin-install.sh). Click the Copy button at the top which is next to the button that saws RAW. Return to your tab with the nodebox cockpit open and in the terminal do this:
```
# return to home directory if you hadn't already.
cd

# create and edit the script.
nano bitcoin-install.sh
```

Right-click and Paste the script you copied from the github page.

Press CTRL+X, then press Y to Save, and then press Enter. You now have the script saved in the home folder. Make it executable and run it.
```
# make the script executable.
chmod +x bitcoin-install.sh

# runs in a detached manner so you can log out of the terminal while this goes on. IBD takes most of a day or more as of 2025.
sudo nohup ./bitcoin-install-tor-only-after-ibd.sh > ~/bitcoin-install.log 2>&1 &

# Use tail to watch the logfile as the script is running. CTRL+C to cancel.
tail -f ~/bitcoin-install.log

```

