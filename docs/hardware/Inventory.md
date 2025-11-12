# ***Network Inventory***

## **WAN**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |     xx.xxx.xxx.xxx      |    80:e8:2c:2d:77:e2     |     HP/Prodesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |          pfSense          |

### *Recap(WAN)*

- Cat6 cable runs from modem[^modem] to WAN interface of ProDesk[^ProDesk].
- WiFi still operational even in bridge mode.
- WiFi is completely run by eero devices in separate VLANs.

#### Tasks(WAN)

- [x] Activate Bridge Mode on Gateway
- [x] Double check firewall rules

[^modem]: [Device from Xfinity](<https://www.xfinity.com/support/articles/broadband-gateways-userguides#:~:text=Xfinity%20Advanced%20Gateway%20(XB7)>)
[^ProDesk]: [Device from Micro Center](<https://www.microcenter.com/product/692358/ProDesk_600_G4_Mini_Desktop_Computer_(Refurbished);_Intel_Core_i5_8th_Gen_8500T_210GHz_Processor;_32GB_RAM;_1TB_Solid_State_Drive;_Intel_UHD_Graphics_>)

## **LAN**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.7.7.1         |    02:26:26:02:0c:15     |     HP/Prodesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |         Firewall          |
|              :x:              |        10.7.7.2         |    1c:2a:a3:2f:10:9b     |          Mokerlink          |           :x:           |           Server[9]           |          Switch           |

### *Recap(LAN)*

- Cat6 cable runs from NIC [^adapter] installed on ProDesk to port 1 of switch (Trunk).
- LAN is the only interface able to route [^MokerLink] ip address.
- DHCP disabled.

[!CAUTION]
> Re-enabling DHCP on this interface will cause problems for all other interfaces.
>> Wife == ***PISSED!***

#### Tasks(LAN)

- [ ] Figure out if DNS is possible for MokerLink Web page.
- [ ] Double check firewall rules

[^adapter]: [Additional NIC adapter from Amazon](<https://a.co/d/dJ4BD2N>)
[^MokerLink]: [Switch from Amazon](<https://a.co/d/gaJvCKV>)

## **Winterfell (VLAN 99 - Management)**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.99.1        |    02:26:26:02:0c:15     |     HP/Prodesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |         Firewall          |
|            mjolnir            |       10.0.99.10        |    28:29:86:80:1a:55     |         APCSmartUPS         |          apcOS          |          Server[1:2]          |            UPS            |
|          prometheus           |       10.0.99.20        |    00:05:1b:dd:f8:28     |      Apple/MacBookPro       |      Ubuntu24.04.3      |             Shelf             |        Prometheus         |
|            oracle             |       10.0.99.30        |    58:8a:5a:31:20:6a     |     Dell/Inspiron153565     |      Ubuntu24.04.3      |             Shelf             |       Prometheus(2)       |

### *Recap(Winterfell)*

- Cat6 cables for each device.
- DHCP enabled.
- VLAN 99 takes up ports 1-3 of Switch.
- Should probably have invested in a battery for the UPS...[^UPS]
- Port 3 connects to an 8-port tp-link switch[^tp-linkswitch] where prometheus and oracle are connected.
- pfSense can only be accessed on this interface from Hicks VLAN.
- prometheus is an old 2012 MacBook Pro[^MacBookPro] with Ubuntu Server installed.
- oracle is an old Dell Laptop[^Dell] with Ubuntu Server installed.

#### Tasks(Winterfell)

- [ ] Get a new battery for UPS.
- [ ] Finish Network Monitoring setup.
  - [ ] Prometheus
  - [ ] Grafana
  - [ ] Loki
  - [ ] SNMP-Exporter
  - [ ] Alloy
- [ ] Deploy Alloy throughout network.
- [ ] Decide on oracle's exact use.

[^UPS]: [Device from ebay](<https://ebay.us/m/vy0d86>)
[^tp-linkswitch]: [Device from Best Buy](<https://www.bestbuy.com/product/tp-link-8-port-10-100-1000-mbps-unmanaged-switch-black/J39QK2QLKC>)
[^MacBookPro]: [Device from Apple](<https://support.apple.com/en-us/111958>)
[^Dell]: [Device from Dell](<https://www.walmart.com/ip/Dell-Inspiron-15-3520-15-6-Full-HD-Touchscreen-Laptop-Intel-Core-i5-1235U-UHD-Graphics-Camera-Wi-Fi-32GB-RAM-2TB-SSD-Windows-11-S/14255402464?wmlspartner=wlpa&selectedSellerId=0&sid=d942e5f1-02bd-424c-9755-321140c3eacc>)

## **Hicks (VLAN 50 - Trusted Devices)**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.50.1        |    02:26:26:02:0c:15     |     HP/ProDesk600G4Mini     |      FreeBSD_15.0       |           Server[5]           |         Firewall          |
|           M_Gaming            |       10.0.50.10        |    04:ed:33:52:6e:94     |     HP/PavillionGaming      |        Windows11        |          LivingRoom           |          Laptop           |
|           M_Desktop           |       10.0.50.20        |    04:42:1a:ec:1f:24     |     ASUS/ROGStrixX570E      |        Windows11        |            Office             |          Desktop          |
|           M_Laptop            |       10.0.50.69        |    e8:f6:73:a4:32:86     |     Microsoft/Surface6      |        Windows11        |            Office             |          Work_PC          |
|           G_Laptop            |       10.0.50.70        |    4c:ea:41:66:f2:70     |     Microsoft/Surface6      |        Windows11        |           Basement            |          Work_PC          |
|           G_MacBook           |       10.0.50.80        |    4c:ea:41:68:b4:c5     |      Apple/MacBookPro       |      MacOSTahoe26       |           Basement            |          Laptop           |
|           G_Desktop           |       10.0.50.90        |    04:42:1a:07:41:ee     |    ASUS/ROGCrosshairVIII    |        Windows11        |           Basement            |          Desktop          |
|             eero              |       10.0.50.104       |    9c:57:bc:76:e3:32     |         eero/Pro6E          |         eeroOS          |          DiningRoom           |           WiFi            |
|           G_iPhone            |       10.0.50.105       |    fe:ee:aa:9a:c6:30     |       Apple/iPhone16        |         iOS26.1         |              :x:              |         Cellphone         |
|            M_Pixel            |       10.0.50.109       |    fa:cc:aa:c6:1e:9c     |        Google/Pixel7        |        Android13        |              :x:              |         Cellphone         |
|             eero              |       10.0.50.110       |    9c:57:bc:77:a6:32     |         eero/Pro6E          |         eeroOS          |           MediaRoom           |           WiFi            |
|             eero              |       10.0.50.111       |    fc:3f:a6:2f:a1:92     |         eero/Pro6E          |         eeroOS          |           Playroom            |           WiFi            |
|            G_Watch            |       10.0.50.112       |    f6:b8:72:17:c2:f3     |        Apple/Watch10        |      watchOS26.0.2      |              :x:              |           Watch           |

### *Recap(Hicks)*

- Cat6 cables for each computer. One eero device wired, and the other two are connected wirelessly.
- DHCP enabled.
- Desktop's were built, Surface's are for work, I'm the Apple guy, and my wife uses everything else
- WiFi: `Hicks:OotyToots!213`

#### Tasks(Hicks)

- [ ] Plan out how to interact with eero API for Home Assistant integration.
- [ ] Decide on how to go about deploying Alloy and where to set up log aggregator.

## **CasaBonita (VLAN 40 - Media)**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.40.1        |    02:26:26:02:0c:15     |     HP/ProDesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |         Firewall          |
|           nibelheim           |       10.0.40.10        |    78:c8:81:68:03:1a     |      Sony/PlayStation5      |           :x:           |           Basement            |        GameConsole        |
|            hyrule             |       10.0.40.20        |    00:05:1b:DE:6a:76     |       Nintendo/Switch       |           :x:           |           Basement            |        GameConsole        |
|           lgwebostv           |       10.0.40.100       |    58:fd:b1:75:be:35     |          LG/OLEDTV          |          webOS          |           MediaRoom           |            TV             |
|           streambox           |       10.0.40.101       |    f0:46:3b:ba:e2:b3     |       Xumo/StreamBox        |          entOS          |           MediaRoom           |       StreamDevice        |

## **ImaginationLAN (VLAN 30 - Testing Environment)**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.30.1        |    02:26:26:02:0c:15     |     HP/ProDesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |         Firewall          |
|             shiva             |       10.0.30.10        |    94:57:a5:51:10:ce     |    HPE/ProliantDL360Gen9    |         Proxmox         |           Server[3]           |          Server           |

## **Skids (VLAN 20 - IoT/Smart Devices)**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.20.1        |    02:26:26:02:0c:15     |     HP/ProDesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |         Firewall          |
|             eero              |       10.0.20.101       |    fc:3f:a6:3b:54:52     |         eero/Pro6E          |         eeroOS          |            Bedroom            |         WiFiMesh          |
|             eero              |       10.0.20.102       |    fc:3f:a6:3c:15:12     |         eero/Pro6E          |         eeroOS          |            Office             |         WiFiMesh          |
|             eero              |       10.0.20.103       |    9c:57:bc:3f:7b:12     |         eero/Pro6E          |         eeroOS          |           Basement            |         WiFiMesh          |
|            bifrost            |       10.0.20.104       |    ec:b5:fa:af:6c:38     |      Philips/HueBridge      |           :x:           |           MediaRoom           |         Lighting          |
|            office             |       10.0.20.105       |    74:d4:23:55:52:3e     |         Amazon/Echo         |           :x:           |            Office             |         Assistant         |
|         litter-robot4         |       10.0.20.108       |    c0:49:ef:e0:90:24     |    Whisker/LitterRobot4     |           :x:           |          LaundryRoom          |         LitterBox         |
|            kitchen            |       10.0.20.109       |    58:a8:e8:7b:83:39     |         Amazon/Echo         |           :x:           |            Kitchen            |         Assistant         |
|        backfloodlight         |       10.0.20.112       |    10:08:2c:22:e3:4f     |       Ring/Floodlight       |           :x:           |            Kitchen            |          Camera           |
|           basement            |       10.0.20.113       |    d4:90:9c:ed:99:0e     |        Apple/HomePod        |           :x:           |           Basement            |         Assistant         |
|          zeke'sroom           |       10.0.20.114       |    1c:fe:2b:88:bf:3f     |         Amazon/Echo         |           :x:           |           ZekeRoom            |         Assistant         |
|          whitenoise           |       10.0.20.115       |    50:8b:b9:DE:1a:a8     |       Tuya/WhiteNoise       |           :x:           |           ZekeRoom            |        WhiteNoise         |
|          babymonitor          |       10.0.20.117       |    a4:97:5c:ae:d6:7e     |        VTech/Camera         |           :x:           |           ZekeRoom            |          Camera           |
|        frontfloodlight        |       10.0.20.118       |    b4:bc:7c:1b:bb:a2     |       Ring/Floodlight       |           :x:           |           Driveway            |          Camera           |
|         frontdoorbell         |       10.0.20.119       |    3c:e1:a1:5d:8e:28     |        Ring/Doorbell        |           :x:           |           FrontDoor           |          Camera           |
|          basestation          |       10.0.20.121       |    2c:6b:7d:0d:e7:e4     |          Ring/Base          |           :x:           |          DiningRoom           |            Hub            |
|            bedroom            |       10.0.20.124       |    94:ea:32:89:4e:96     |        Apple/HomePod        |           :x:           |            Bedroom            |         Assistant         |
|            garage             |       10.0.20.126       |    54:e0:19:3e:77:23     |         Ring/Camera         |           :x:           |            Garage             |          Camera           |
|            kitchen            |       10.0.20.128       |    f4:34:f0:23:a7:22     |        Apple/HomePod        |           :x:           |            Kitchen            |         Assistant         |
|            kitchen            |       10.0.20.130       |    54:e0:19:3c:fe:7d     |         Ring/Camera         |           :x:           |            Kitchen            |          Camera           |
|           mediaroom           |       10.0.20.132       |    f4:34:f0:22:16:2c     |        Apple/HomePod        |           :x:           |           MediaRoom           |         Assistant         |
|          livingroom           |       10.0.20.133       |    4c:ef:c0:f7:95:c6     |         Amazon/Echo         |           :x:           |          LivingRoom           |         Assistant         |
|            tablet             |       10.0.20.136       |    a2:24:fc:48:25:32     |        VTech/Tablet         |           :x:           |            Bedroom            |          Tablet           |

## **Degens (VLAN 10 - Guest Network)**

| $\color{limegreen}{Hostname}$ | $\color{limegreen}{IP}$ | $\color{limegreen}{MAC}$ | $\color{limegreen}{Device}$ | $\color{limegreen}{OS}$ | $\color{limegreen}{Location}$ | $\color{limegreen}{Role}$ |
| :---------------------------: | :---------------------: | :----------------------: | :-------------------------: | :---------------------: | :---------------------------: | :-----------------------: |
|           morpheus            |        10.0.10.1        |    02:26:26:02:0c:15     |     HP/ProDesk600G4Mini     |       FreeBSD15.0       |           Server[5]           |         Firewall          |
|             eero              |       10.0.10.10        |    fc:3f:a6:2c:66:d2     |         eero/Pro6E          |         eeroOS          |            Kitchen            |         WiFiMesh          |
|             eero              |       10.0.10.101       |    9c:57:bc:6b:29:b2     |         eero/Pro6E          |         eeroOS          |          LivingRoom           |         WiFiMesh          |

### Miscellaneous Items

- Patch panel/cables
- Ethernet couplers
- RJ-45
- Server Rack
