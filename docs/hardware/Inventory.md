# HomeLab Hardware Inventory

## WAN Network

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |     73.140.244.168      |    80:e8:2c:2d:77:e2     |   HP/Prodesk_600_G4_Mini    |  FreeBSD_15.0_Current   |           Server[5]           |          pfSense          |

## LAN Network

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.7.7.1         |    02:26:26:02:0c:15     |   HP/Prodesk_600_G4_Mini    |  FreeBSD_15.0_Current   |           Server[5]           |         Firewall          |
|              :x:              |        10.7.7.2         |    1c:2a:a3:2f:10:9b     |          Mokerlink          |           :x:           |           Server[9]           |          Switch           |

## Winterfell (VLAN 99 - Management)

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.99.1        |    02:26:26:02:0c:15     |   HP/Prodesk_600_G4_Mini    |  FreeBSD_15.0_Current   |           Server[5]           |         Firewall          |
|            mjolnir            |       10.0.99.10        |    28:29:86:80:1a:55     |        APC Smart UPS        |         APC OS          |          Server[1-2]          |            UPS            |
|          prometheus           |       10.0.99.20        |    00:05:1b:dd:f8:28     |      Apple_MacBookPro       |     Ubuntu 24.04.3      |             Shelf             |        Prometheus         |
|            oracle             |       10.0.99.30        |    58:8a:5a:31:20:6a     |    Dell_Inspiron_15_3565    |     Ubuntu 24.04.3      |             Shelf             |       Prometheus(2)       |

## Hicks (VLAN 50 - Trusted Devices)

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.50.1        |    02:26:26:02:0c:15     |   HP/ProDesk_600_G4_Mini    |  FreeBSD_15.0_Current   |           Server[5]           |         Firewall          |
|           M_Gaming            |       10.0.50.10        |    04:ed:33:52:6e:94     |     HP Pavillion Gaming     |       Windows 11        |          Living_Room          |          Laptop           |
|           M_Desktop           |       10.0.50.20        |    04:42:1a:ec:1f:24     |    ASUS/ROG Strix X570-E    |       Windows 11        |            Office             |          Desktop          |
|           M_Laptop            |       10.0.50.69        |    e8:f6:73:a4:32:86     |     Microsoft Surface 6     |       Windows 11        |            Office             |          Work_PC          |
|           G_Laptop            |       10.0.50.70        |    4c:ea:41:66:f2:70     |     Microsoft Surface 6     |       Windows 11        |           Basement            |          Work_PC          |
|           G_MacBook           |       10.0.50.80        |    4c:ea:41:68:b4:c5     |      Apple MacBook Pro      |   MacOS_Tahoe_26.0.1    |           Basement            |          Laptop           |
|           G_Desktop           |       10.0.50.90        |    04:42:1a:07:41:ee     |   ASUS/ROG Crosshair VIII   |       Windows 11        |           Basement            |          Desktop          |
|             eero              |       10.0.50.104       |    9c:57:bc:76:e3:32     |         eero Pro 6E         |         eeroOS          |          Dining_Room          |           WiFi            |
|           G_iPhone            |       10.0.50.105       |    fe:ee:aa:9a:c6:30     |       Apple iPhone 16       |        iOS 26.1         |              :x:              |         Cellphone         |
|            M_Pixel            |       10.0.50.109       |    fa:cc:aa:c6:1e:9c     |       Google Pixel 7        |       Android 13        |              :x:              |         Cellphone         |
|             eero              |       10.0.50.110       |    9c:57:bc:77:a6:32     |         eero Pro 6E         |         eeroOS          |          Media_Room           |           WiFi            |
|             eero              |       10.0.50.111       |    fc:3f:a6:2f:a1:92     |         eero Pro 6E         |         eeroOS          |           Playroom            |           WiFi            |
|            G_Watch            |       10.0.50.112       |    f6:b8:72:17:c2:f3     |       Apple_Watch_10        |     watchOS_26.0.2      |              :x:              |           Watch           |

## CasaBonita (VLAN 40 - Media)

|    Hostname     |     IP      | MAC               | Make     |        Model        | CPU                                     | RAM    | Storage   |   BIOS Version    |   Operating System   | Software/Services |         Location          | Credentials |      Notes       |
| :-------------: | :---------: | ----------------- | :------- | :-----------------: | --------------------------------------- | ------ | --------- | :---------------: | :------------------: | :---------------: | :-----------------------: | ----------- | :--------------: |
|    morpheus     |  10.0.40.1  | 02:26:26:02:0c:15 | HP       | ProDesk 600 G4 Mini | Intel(R) Core(TM) i5-8500 CPU @ 3.00GHz | 2x16GB | 1TB SSD   | Q22 Ver. 02.29.01 | FreeBSD 15.0-Current |      pfSense      | Basement (Server Rack[5]) | :x:         |     Firewall     |
|    nibelheim    | 10.0.40.10  | 78:c8:81:68:03:1a | Sony     |    PlayStation 5    | AMD Zen 2                               | 16GB   | 825GB SSD |        :x:        |         :x:          |        :x:        |         Basement          | :x:         |  Gaming Console  |
|     hyrule      | 10.0.40.20  | 00:05:1b:de:6a:76 | Nintendo |       Switch        | NVIDIA Custom Tegra Processor           | 8GB    | 32GB      |        :x:        |         :x:          |        :x:        |         Basement          | :x:         |  Gaming Console  |
|    lgwebostv    | 10.0.40.100 | 58:fd:b1:75:be:35 | LG       |       OLED TV       | a9 GEN 3 AI Processor 4K                | :x:    | :x:       |        :x:        |        webOS         |        :x:        |        Media Room         | :x:         |        TV        |
| entos-streambox | 10.0.40.101 | f0:46:3b:ba:e2:b3 | Xumo     |     Stream Box      | Quad Core                               | :x:    | :x:       |        :x:        |        entOS         |        :x:        |        Media Room         | :x:         | Streaming Device |

## ImaginationLAN (VLAN 30 - Testing Environment)

| Hostname |     IP     | MAC               | Make |        Model        | CPU                                     | RAM    | Storage    |   BIOS Version    |   Operating System   | Software/Services |         Location          | Credentials            |  Notes   |
| :------: | :--------: | ----------------- | :--- | :-----------------: | --------------------------------------- | ------ | ---------- | :---------------: | :------------------: | :---------------: | :-----------------------: | ---------------------- | :------: |
| morpheus | 10.0.30.1  | 02:26:26:02:0c:15 | HP   | ProDesk 600 G4 Mini | Intel(R) Core(TM) i5-8500 CPU @ 3.00GHz | 2x16GB | 1TB SSD    | Q22 Ver. 02.29.01 | FreeBSD 15.0-Current |      pfSense      | Basement (Server Rack[5]) | :x:                    | Firewall |
|  shiva   | 10.0.30.10 | 94:57:a5:51:10:ce | HPE  | Proliant DL360 Gen9 | 2x Intel Xeon E5-2680 V3 2.5Ghz         | 8x16GB | 2x1TB SATA |     P89 v3.40     |       Proxmox        |        iLO        | Basement (Server Rack[3]) | administrator/73GYZTNS |  Server  |

## Skids (VLAN 20 - IoT/Smart Devices)

|     Hostname      |     IP      | MAC               | Make    |           Model           |                   CPU                   | RAM    | Storage |   BIOS Version    |   Operating System   | Software/Services |         Location          | Credentials                    |       Notes        |
| :---------------: | :---------: | ----------------- | :------ | :-----------------------: | :-------------------------------------: | ------ | ------- | :---------------: | :------------------: | :---------------: | :-----------------------: | ------------------------------ | :----------------: |
|     morpheus      |  10.0.20.1  | 02:26:26:02:0c:15 | HP      |    ProDesk 600 G4 Mini    | Intel(R) Core(TM) i5-8500 CPU @ 3.00GHz | 2x16GB | 1TB SSD | Q22 Ver. 02.29.01 | FreeBSD 15.0-Current |      pfSense      | Basement (Server Rack[5]) | :x:                            |      Firewall      |
|       eero        | 10.0.20.101 | fc:3f:a6:3b:54:52 | eero    |          Pro 6E           |                   :x:                   | :x:    | :x:     |        :x:        |        eeroOS        |        :x:        |          Bedroom          | Skids/FAKU&SkidsRiot_Stuart!69 |  WiFi Mesh System  |
|       eero        | 10.0.20.102 | fc:3f:a6:3c:15:12 | eero    |          Pro 6E           |                   :x:                   | :x:    | :x:     |        :x:        |        eeroOS        |        :x:        |          Office           | Skids/FAKU&SkidsRiot_Stuart!69 |  WiFi Mesh System  |
|       eero        | 10.0.20.103 | 9c:57:bc:3f:7b:12 | eero    |          Pro 6E           |                   :x:                   | :x:    | :x:     |        :x:        |        eeroOS        |        :x:        |         Basement          | Skids/FAKU&SkidsRiot_Stuart!69 |  WiFi Mesh System  |
|      bifrost      | 10.0.20.104 | ec:b5:fa:af:6c:38 | Philips |        Hue Bridge         |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Media Room         | :x:                            | Smart Light System |
|      office       | 10.0.20.105 | 74:d4:23:55:52:3e | Amazon  |           Echo            |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Office           | :x:                            | Digital Assistant  |
|   litter-robot4   | 10.0.20.108 | c0:49:ef:e0:90:24 | Whisker |      Litter-Robot 4       |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |       Laundry Room        | :x:                            |    Smart Device    |
|      kitchen      | 10.0.20.109 | 58:a8:e8:7b:83:39 | Amazon  |           Echo            |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Kitchen          | :x:                            | Digital Assistant  |
| gardenfloodlight  | 10.0.20.112 | 10:08:2c:22:e3:4f | Ring    |     Floodlight Camera     |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |    Kitchen - Back Door    | :x:                            |    Smart Camera    |
|     basement      | 10.0.20.113 | d4:90:9c:ed:99:0e | Apple   |          HomePod          |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |         Basement          | :x:                            | Digital Assistant  |
|    zeke'sroom     | 10.0.20.114 | 1c:fe:2b:88:bf:3f | Amazon  |           Echo            |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Zeke's Room        | :x:                            | Digital Assistant  |
| whitenoisemachine | 10.0.20.115 | 50:8b:b9:de:1a:a8 | Tuya    | Smart White Noise Machine |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Zeke's Room        | :x:                            |    Smart Device    |
|    babymonitor    | 10.0.20.117 | a4:97:5c:ae:d6:7e | VTech   |          RM7764           |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Zeke's Room        | :x:                            |    Smart Camera    |
|  frontfloodlight  | 10.0.20.118 | b4:bc:7c:1b:bb:a2 | Ring    |     Floodlight Camera     |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |         Driveway          | :x:                            |    Smart Camera    |
|   frontdoorbell   | 10.0.20.119 | 3c:e1:a1:5d:8e:28 | Ring    |      Doorbell Camera      |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Front Door         | :x:                            |    Smart Camera    |
|    basestation    | 10.0.20.121 | 2c:6b:7d:0d:e7:e4 | Ring    |       Base Station        |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Dining Room        | :x:                            |    Smart Device    |
|      bedroom      | 10.0.20.124 | 94:ea:32:89:4e:96 | Apple   |       HomePod Mini        |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Bedroom          | :x:                            | Digital Assistant  |
|      garage       | 10.0.20.126 | 54:e0:19:3e:77:23 | Ring    |          Camera           |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Garage           | :x:                            |    Smart Camera    |
|      kitchen      | 10.0.20.128 | f4:34:f0:23:a7:22 | Apple   |       HomePod Mini        |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Kitchen          | :x:                            | Digital Assistant  |
|      kitchen      | 10.0.20.130 | 54:e0:19:3c:fe:7d | Ring    |          Camera           |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Kitchen          | :x:                            |    Smart Camera    |
|     mediaroom     | 10.0.20.132 | f4:34:f0:22:16:2c | Apple   |       HomePod Mini        |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Media Room         | :x:                            | Digital Assistant  |
|    livingroom     | 10.0.20.133 | 4c:ef:c0:f7:95:c6 | Amazon  |           Echo            |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |        Living Room        | :x:                            | Digital Assistant  |
| babymonitortablet | 10.0.20.136 | a2:24:fc:48:25:32 | VTech   |      Monitor Tablet       |                   :x:                   | :x:    | :x:     |        :x:        |         :x:          |        :x:        |          Bedroom          | :x:                            |    Smart Device    |

## Degens (VLAN 10 - Guest Network)

|          Hostname          | IP  | MAC | Make | Model | CPU | RAM | Storage | BIOS Version | Operating System | Software/Services | Location | Credentials | Notes |
| :------------------------: | :-: | --- | :--- | :---: | --- | --- | ------- | :----------: | :--------------: | :---------------: | :------: | ----------- | :---: |
| No current house guests :) |     |     |      |       |     |     |         |              |                  |                   |          |             |       |

## Miscellaneous

| Hostname | IP  | MAC | Model | Serial # | BIOS Version | Firmware/Drivers | Operating System | Software/Services | Location |
| -------- | --- | --- | ----- | -------- | ------------ | ---------------- | ---------------- | ----------------- | -------- |

### Additional Notes

- All devices within the lab will be accessed from Desktop.
- Additional servers will be added as needed, and when the price is right.
