# wan-dhcp

Independently selectable Clan service, role `host`, for x86_64-linux.

Requires `interface` (a canonical Linux interface name) and `macAddress`.
The native systemd `.link` matches the MAC and names the interface. Network
selects systemd-networkd, disables global DHCP and enables ordinary DHCP on
this interface. Host IPv6 policy belongs to native `networking.enableIPv6`;
there is no WAN-specific IPv6 override.

Multiple DHCP selections are supported on distinct physical interfaces. The
shared internal WAN ownership check rejects duplicate interface names and
case-insensitive MAC identities across DHCP and static selections. It retains
only physical ownership facts, with no consumer registry or allocated IDs.
A host may select at most one static WAN service.

Without a WAN selection Network does not change external networking. Physical
NIC/udev renaming and a deployed DHCP server require separate machine acceptance.
