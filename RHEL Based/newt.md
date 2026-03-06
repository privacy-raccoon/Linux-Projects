# Install newt and configure to connect to Pangolin

If you are using Pangolin as a reverse proxy, you'll want to set up a Site in Pangolin, then install Newt and configure a systemd service.

## Walkthrough

Install newt with the following command:
`curl -fsSL https://static.pangolin.net/get-newt.sh | bash`

Copy newt to `/usr/local/bin/`:
`sudo cp /home/$USERNAME/.local/bin/newt /usr/local/bin/newt`

Where `$USERNAME` = your username

Create a systemd daemon config file at `/etc/systemd/system/newt.service`

```ini
[Unit]
Description=Pangolin Newt Tunnel Client
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/newt --id $NEWT_ID --secret $NEWT_SECRET --endpoint $NEWT_ENDPOINT
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

`$NEWT_ID` = The ID provided by Pangolin
`$NEWT_SECRET` = The secret provided by Pangolin
`$NEWT_ENDPOINT` = Your Pangolin endpoint

Unfortunately you can't really obfuscate the client ID or secret. Every way I try ends up causing the service to fail.

Run the following:

```bash
systemctl daemon-reload
systemctl enable newt.service --now
```

Altogether, you could use a script that looks like this:

```bash
curl -fsSL https://static.pangolin.net/get-newt.sh | bash
cp /home/$WHOAMI/.local/bin/newt /usr/local/bin/newt

cat <<EOF > /etc/systemd/system/newt.service
[Unit]
Description=Pangolin Newt Tunnel Client
After=network-online.target
Wants=network-online.target

printf "\nPlease enter the Newt ID: "
read -r NEWT_ID
printf "\nPlease enter the Newt Secret: "
read -r NEWT_SECRET
printf "\nPlease enter the Pangolin endpoint: "
read -r NEWT_ENDPOINT

[Service]
ExecStart=/usr/local/bin/newt --id $NEWT_ID --secret $NEWT_SECRET --endpoint $NEWT_ENDPOINT
Restart=on-failure
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable newt.service --now

```

Please note: you may need to make some adjustments based on your environment.
