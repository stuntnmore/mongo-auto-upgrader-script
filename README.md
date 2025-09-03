### MongoDB Upgrade Script (mongodb-upgrade-clean.sh)

#### Overview

- **Purpose**: Safely upgrade MongoDB from 3.2+ to 7.0.14 on Ubuntu 18.04/20.04/22.04 with minimal manual steps.
- **Highlights**:
  - **Single initial backup** using `mongodump` (one-time snapshot before any changes).
  - **Sequential, version-aware upgrades** with automatic skipping of already-completed steps.
  - **FCV management** per version with automatic `confirm: true` for MongoDB 7.0.
  - **MMAPv1 → WiredTiger migration** at 4.0 only when needed (skipped if already WiredTiger).
  - **7.x config safety**: Disables `journal` in `mongod.conf` before starting 7.x binaries.
  - **Compatibility**: Adds `ppa:xapienz/curl34` and installs `libcurl3` for MongoDB 4.0+ on all supported Ubuntu versions.
  - **System hardening**: Fixes permissions and raises `nofile`/`nproc` limits (limits.d + systemd).
  - **Robust control & logs**: Safe start/stop with retries; logs to `/var/log/mongodb-upgrade.log`.

#### Requirements

- **OS**: Ubuntu 18.04, 20.04, or 22.04
- **Access**: Root (`sudo`)
- **Resources**: 10GB+ free disk, internet
- **MongoDB config**: `/etc/mongod.conf`

#### Upgrade Path

- 3.2 → 3.4 → 3.6 → 4.0 → 4.2 → 4.4 → 5.0 → 6.0 → 7.0.14
- Binaries used automatically per OS:
  - Ubuntu 18.04: `ubuntu1804` (older steps may use `ubuntu1604` where needed)
  - Ubuntu 20.04: `ubuntu2004`
  - Ubuntu 22.04: `ubuntu2204`
- Special handling for 7.x: Comments out `journal:` and `enabled: true` before starting 7.x.

#### What the script does

1. Pre-flight: root check, disk/memory info, Ubuntu compatibility
2. Installs deps: `wget`, `curl`, `software-properties-common`, adds libcurl3 PPA, fixes `growroot` hook
3. Detects port from `mongod.conf`, detects MongoDB version
4. Aligns FCV to current version (if MongoDB is running)
5. Creates a single backup to `/backup/<timestamp>` using `mongodump`
6. Temporarily disables auth in `mongod.conf`
7. Starts MongoDB with permissions and system limits fixed
8. Re-checks/sets FCV for the running version
9. Runs the upgrade sequence step-by-step (skipping already satisfied steps)
   - At 4.0, migrates MMAPv1 → WiredTiger only if needed
   - For 7.x, disables journaling before starting the new binary and sets FCV with `confirm: true`
10. Installs `mongosh` and verifies server version, storage engine, FCV, and basic data stats
11. Restores auth and restarts MongoDB
12. Prints final summary and tests connectivity

#### How to run

```bash
cd /home/ubuntu/popstand/nexus/ExpoSync
chmod +x ./mongodb-upgrade-clean.sh
sudo ./mongodb-upgrade-clean.sh
```

- Confirm when prompted:

```text
Type 'UPGRADE' to proceed: UPGRADE
```

#### Logs

```bash
tail -f /var/log/mongodb-upgrade.log
```

#### Verify after upgrade

- Server version:
```bash
mongosh --eval "db.version()"
```

- FCV:
```bash
mongosh --eval "db.adminCommand({getParameter:1, featureCompatibilityVersion:1})"
```

- Storage engine:
```bash
mongosh --eval "db.serverStatus().storageEngine.name"
```

#### Notes

- The script is idempotent and safe to re-run; it will skip steps already done.
- Downtime is expected during restarts; schedule a maintenance window.
- If you are on Ubuntu 16.04, upgrade OS to at least 18.04 first 

