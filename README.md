# Homelab

## DHCP Structure
-----------------------------------
100 Revenant      Platform <br>
101 Poltergeist   Home Assistant <br>
102 Banshee       Frigate <br>
103 Djinn         Vaultwarden <br>
104 Torii         Edge <br>
105 Sentinel      Authentik <br>
106 Watcher       Monitoring <br>
107 Reserved <br>
108 Phantasm      Immich <br>
109 Reserved <br>
110 Wisp          Games <br>

120 Grimoire      Windows Dev <br>
121+              Dev/Test <br>
<br>
<br>
## Ubuntu VM bootstrap
<br>

```bash
curl -fsSL https://raw.githubusercontent.com/USERNAME/homelab/main/bootstrap/ubuntu-vm.sh -o /tmp/ubuntu-vm.sh \
  && bash /tmp/ubuntu-vm.sh
