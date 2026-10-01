# KijaniKiosk Access Model

This document records the access design applied to `/opt/kijanikiosk` and the reasoning behind each decision. The guiding principle is least privilege: every account and directory gets the minimum access needed for its function and nothing more.

## Service accounts

| Account | UID range | Shell | Home | Primary group | Purpose |
|---|---|---|---|---|---|
| `kk-api` | system (<1000) | `/usr/sbin/nologin` | `/nonexistent` | `kk-api` | Runs the API component |
| `kk-payments` | system (<1000) | `/usr/sbin/nologin` | `/nonexistent` | `kk-payments` | Runs the payment processor |
| `kk-logs` | system (<1000) | `/usr/sbin/nologin` | `/nonexistent` | `kk-logs` | Runs the log aggregator |

Each service runs under its own account so that a compromise of one component cannot read or modify another's files. Each account has its own primary group, which keeps group ownership meaningful per component. All three, plus the regular admin user, belong to a shared `kijanikiosk` group used only for traverse access to the top of the tree.

## Directory access table

| Path | Owner:Group | Mode | Access model | Reasoning |
|---|---|---|---|---|
| `/opt/kijanikiosk/` | `root:kijanikiosk` | `750` | basic | Root owns the tree so no service can alter the structure. The `kijanikiosk` group gets `r-x` to traverse into subdirectories; `x` is what allows passing through. Everyone else is blocked at the top, which contains the whole tree. |
| `/opt/kijanikiosk/api/` | `kk-api:kk-api` | `750` | basic | Only the API account needs its code. `750` gives the owner full access, the group `r-x`, and no access to others. No cross-service or world access is required, so basic permissions are sufficient. |
| `/opt/kijanikiosk/payments/` | `kk-payments:kk-payments` | `750` | basic | Same pattern as `api/`, isolated to the payments account. Payment code is sensitive, so no other service can read it. |
| `/opt/kijanikiosk/logs/` | `kk-logs:kk-logs` | `750` | basic | Same pattern, isolated to the logs account. |
| `/opt/kijanikiosk/config/` | `root:kijanikiosk` | dir `750`, files `640` | basic + one ACL | Secrets live here (DB password, payment keys). Root owns and is the only writer. The `kijanikiosk` group reads via `640`, so services can load config but not change it. A named ACL grants the admin user read access explicitly, independent of group membership. |
| `/opt/kijanikiosk/shared/logs/` | `kk-logs:kk-logs` | `2770` | basic + ACLs | A shared drop point where several accounts have different levels of access. The SGID bit (`2`) forces every new file to the `kk-logs` group regardless of who created it, keeping ownership consistent. Cross-account differences are expressed with ACLs. |

## Why ACLs where standard permissions were not enough

Standard Unix permissions offer exactly three sets: owner, one group, and other. That is enough when everyone in a directory needs the same level of access, which is why `api/`, `payments/` and `logs/` use basic permissions only.

`shared/logs/` breaks that model. Three different identities need three different levels of access to the same directory:

- `kk-api` needs to **write** logs (`rwx`)
- `kk-payments` needs to **read** logs (`r-x`)
- the admin user needs to **read** logs (`r-x`)

The directory is owned by `kk-logs`, so the single group slot is spoken for. There is no way to express "kk-api writes, kk-payments reads, admin reads" with one owner, one group and other. POSIX ACLs solve this by attaching additional named-user and named-group entries beyond the base three. Each account gets its own entry:

```
setfacl -m u:kk-api:rwx      /opt/kijanikiosk/shared/logs
setfacl -m u:kk-payments:rx  /opt/kijanikiosk/shared/logs
setfacl -m u:<admin>:rx      /opt/kijanikiosk/shared/logs
```

Default ACLs (`setfacl -d`) were added so that files created later inherit the same access. Without them, a new log file would carry only the base permissions, and kk-payments and the admin could list new files but not read them.

For `config/`, group `640` already gives the admin read access through the `kijanikiosk` group, so an ACL is not strictly required. A named ACL for the admin was added anyway to satisfy the task and to keep the admin's access explicit and durable even if the group membership changes.

## Why these specific modes

- **`750` for directories** (owner `rwx`, group `r-x`, other none): the owning service manages its own directory, the group can enter and read, and no unintended user has any access. `755` was rejected because it would let every user on the system read the code.
- **`640` for sensitive files** (owner `rw-`, group `r--`, other none): the owner edits, the group reads, others get nothing. Config files hold secrets, so world access is never acceptable. `644` was rejected for the same reason.
- **`2770` for `shared/logs`** (SGID, owner `rwx`, group `rwx`, other none): writers in the group can create files, the SGID bit unifies group ownership, and others are excluded. The finer per-account distinctions are layered on top with ACLs.
