# Research sources and third-party notices

AggroRange's exception research used NPC IDs, names, levels, and detection values from the projects below, alongside AggroRange's own policy decisions and selected live Classic Era observations. The retained research records and source annotations appear in `Exceptions.lua`. Emulator values are research inputs, not authoritative measurements of Blizzard's live servers.

## CMaNGOS / ClassicDB

- Project: https://github.com/cmangos/classic-db
- Research revision: `22b51464f1625f6ef6275771de1f5466c6f5d19e`.
- Research input: the ClassicDB full database plus updates at that revision.
- [Upstream README](https://github.com/cmangos/classic-db/blob/22b51464f1625f6ef6275771de1f5466c6f5d19e/README.md) identifies GPL version 3 and separately identifies Blizzard material outside that grant.
- Preserved notices: [ClassicDB license](LICENSES/ClassicDB-LICENSE.md) and [ClassicDB copyright notice](LICENSES/ClassicDB-COPYRIGHT.md), copied unchanged from that revision.

## VMaNGOS

- Project: https://github.com/vmangos/core
- Research revision: `13b49dc36f41a49221cf4f4b311809b4f649e8a8`.
- Research input: database snapshot `db-13b49dc.zip`, selecting the highest eligible patch record up to Vanilla 1.12 for the comparison.
- Preserved notice: [VMaNGOS repository license](LICENSES/VMaNGOS-LICENSE.txt), copied unchanged from that revision. It contains GPL version 2 and an OpenSSL exception.
- This is the repository notice; the complete notices accompanying that particular database archive have not been independently verified.

## Scope

These notices document provenance and preserve the retrieved upstream terms. Their inclusion does not relicense third-party material, establish that every retained record is copyrightable, or establish the license applicable to AggroRange as a whole. Any applicable third-party rights and obligations remain in force. AggroRange's custom license applies only to rights held or controlled by Lichdom.

World of Warcraft and related Blizzard intellectual property belong to Blizzard Entertainment and its licensors. No endorsement by Blizzard, CMaNGOS, or VMaNGOS is implied.
